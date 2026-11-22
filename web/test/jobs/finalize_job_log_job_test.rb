require "test_helper"

class FinalizeJobLogJobTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    clear_enqueued_jobs
    @project = Project.create!(name: "finalize-log")
    pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    workflow = pipeline.workflow_runs.create!(name: "wf", status: "running")
    @job = workflow.job_runs.create!(name: "build", status: "running")
    @job.append_log_chunk!(1, "second\n")
    @job.append_log_chunk!(0, "first\n")
  end

  teardown do
    @project.reload.destroy!
    clear_enqueued_jobs
  end

  def with_service_override(method, replacement)
    service = ActiveStorage::Blob.service
    original = service.method(method)
    service.define_singleton_method(method, replacement)
    yield
  ensure
    service.define_singleton_method(method, original)
  end

  test "upload failure preserves buffered logs and retry finalizes exact text" do
    with_service_override(:upload, ->(*) { raise IOError, "injected upload failure" }) do
      assert_no_difference "ActiveStorage::Blob.count" do
        @job.transition_to!("success")
        FinalizeJobLogJob.perform_now(@job.id)
      end
    end
    assert_equal 2, @job.reload.log_chunks.count
    assert_equal "first\nsecond\n", @job.log_text
    assert_not @job.log_complete?
    get "/api/v1/jobs/#{@job.id}/logs", headers: admin_headers
    assert_response :ok
    assert_equal "first\nsecond\n", json_body["chunks"].map { |c| c["chunk"] }.join
    assert_equal false, json_body["complete"]
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal "first\nsecond\n", @job.reload.log_blob.download
    assert_empty @job.log_chunks
    assert @job.log_complete?
  end

  test "enqueue waits for outer commit and rollback never enqueues" do
    JobRun.transaction do
      @job.transition_to!("success")
      assert_enqueued_jobs 0, only: FinalizeJobLogJob
      assert_equal 2, @job.log_chunks.count
    end
    assert_enqueued_jobs 1, only: FinalizeJobLogJob
    clear_enqueued_jobs
    @job.reset_for_rerun!
    JobRun.transaction do
      @job.cancel!
      raise ActiveRecord::Rollback
    end
    assert_enqueued_jobs 0, only: FinalizeJobLogJob
  end

  test "idempotent with missing active empty and already finalized jobs" do
    FinalizeJobLogJob.perform_now(-1)
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal 2, @job.log_chunks.count
    @job.transition_to!("success")
    FinalizeJobLogJob.perform_now(@job.id)
    blob_id = @job.reload.log_blob.blob.id
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal blob_id, @job.reload.log_blob.blob.id
    @job.log_blob.purge
    FinalizeJobLogJob.perform_now(@job.id)
    assert_not @job.reload.log_blob.attached?
  end

  test "late legacy runner chunks preserve the previously finalized log" do
    token, raw = RunnerToken.generate!(name: "legacy-runner", resource_class: "medium")
    @job.update!(claimed_by: token.name)
    @job.transition_to!("success")
    FinalizeJobLogJob.perform_now(@job.id)
    original = @job.reload.log_blob.download

    post "/api/v1/jobs/#{@job.id}/log_chunks", params: { seq: 2, chunk: "late output ✓\n" },
         headers: bearer_headers(raw), as: :json
    assert_response :ok
    assert_equal 1, @job.log_chunks.count

    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal original + "late output ✓\n".b, @job.reload.log_blob.download
    assert_empty @job.log_chunks
    assert @job.log_complete?
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal original + "late output ✓\n".b, @job.reload.log_blob.download
  ensure
    token&.destroy!
  end

  test "verification failure and exhausted retries retain chunks" do
    @job.transition_to!("success")
    with_service_override(:exist?, ->(*) { false }) do
      assert_no_difference "ActiveStorage::Blob.count" do
        assert_enqueued_with(job: FinalizeJobLogJob) { FinalizeJobLogJob.perform_now(@job.id) }
        assert_raises(FinalizeJobLogJob::StorageError) do
          FinalizeJobLogJob.new(@job.id).tap { |j| j.exception_executions = { [FinalizeJobLogJob::StorageError].to_s => 9 } }.perform_now
        end
      end
    end
    assert_not @job.reload.log_blob.attached?
    assert_equal "first\nsecond\n", @job.reload.log_text
    assert_equal 2, @job.log_chunks.count
    assert_not @job.log_complete?
  end

  test "rerun during upload cannot delete or attach to the new attempt" do
    @job.transition_to!("success")
    service = ActiveStorage::Blob.service
    upload = service.method(:upload)
    job = @job
    with_service_override(:upload, ->(*args, **kwargs) {
      upload.call(*args, **kwargs)
      job.reset_for_rerun!
      job.append_log_chunk!(0, "new attempt\n")
    }) { assert_no_difference("ActiveStorage::Blob.count") { FinalizeJobLogJob.perform_now(@job.id) } }
    assert_equal "new attempt\n", @job.reload.log_text
    assert_not @job.log_blob.attached?
  end

  test "chunks arriving during upload are not deleted" do
    @job.transition_to!("success")
    upload = ActiveStorage::Blob.service.method(:upload)
    job = @job
    with_service_override(:upload, ->(*args, **kwargs) {
      upload.call(*args, **kwargs)
      job.append_log_chunk!(2, "late\n")
    }) do
      assert_no_difference "ActiveStorage::Blob.count" do
        assert_enqueued_with(job: FinalizeJobLogJob, args: [@job.id]) { FinalizeJobLogJob.perform_now(@job.id) }
      end
    end
    assert_equal [0, 1, 2], @job.log_chunks.order(:seq).pluck(:seq)
    assert_not @job.log_complete?
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal "first\nsecond\nlate\n", @job.reload.log_blob.download
  end

  test "corrupt upload is never attached and its stored object is purged" do
    @job.transition_to!("success")
    key = nil
    upload = ActiveStorage::Blob.service.method(:upload)
    with_service_override(:upload, ->(uploaded_key, *args, **kwargs) {
      key = uploaded_key
      upload.call(uploaded_key, *args, **kwargs)
    }) do
      with_service_override(:download, ->(*) { "corrupt" }) do
        assert_no_difference "ActiveStorage::Blob.count" do
          assert_enqueued_with(job: FinalizeJobLogJob) { FinalizeJobLogJob.perform_now(@job.id) }
        end
      end
    end
    assert_not_nil key
    assert_not ActiveStorage::Blob.service.exist?(key)
    assert_not @job.reload.log_blob.attached?
    assert_equal "first\nsecond\n", @job.log_text
  end

  test "attachment failure purges the uploaded blob and retains chunks" do
    @job.transition_to!("success")
    job_id = @job.id
    failure = ->(attachment) { raise "injected attach failure" if attachment.record_type == "JobRun" && attachment.record_id == job_id }
    ActiveStorage::Attachment.set_callback(:create, :before, failure)
    assert_no_difference "ActiveStorage::Blob.count" do
      assert_raises(RuntimeError) { FinalizeJobLogJob.new.perform(@job.id) }
    end
    assert_not @job.reload.log_blob.attached?
    assert_equal 2, @job.log_chunks.count
  ensure
    ActiveStorage::Attachment.skip_callback(:create, :before, failure)
  end

  test "sweep recovers old terminal logs but skips recent active and empty jobs" do
    assert_no_enqueued_jobs(only: FinalizeJobLogJob) { SweepJobLogsJob.perform_now }
    @job.transition_to!("success")
    clear_enqueued_jobs
    assert_no_enqueued_jobs(only: FinalizeJobLogJob) { SweepJobLogsJob.perform_now }
    @job.update_column(:updated_at, 6.minutes.ago)
    assert_enqueued_with(job: FinalizeJobLogJob, args: [@job.id]) { SweepJobLogsJob.perform_now }
    perform_enqueued_jobs(only: FinalizeJobLogJob)
    assert @job.reload.log_complete?
    assert_no_enqueued_jobs(only: FinalizeJobLogJob) { SweepJobLogsJob.perform_now }
    @job.reset_for_rerun!
    @job.append_log_chunk!(0, "new attempt")
    @job.update_column(:updated_at, 6.minutes.ago)
    assert_no_enqueued_jobs(only: FinalizeJobLogJob) { SweepJobLogsJob.perform_now }
  end
end
