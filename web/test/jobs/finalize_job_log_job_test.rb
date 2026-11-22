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
    @project.destroy!
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
      begin
        @job.transition_to!("success")
        FinalizeJobLogJob.perform_now(@job.id)
      rescue IOError
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

  test "verification failure and exhausted retries retain chunks" do
    @job.transition_to!("success")
    with_service_override(:exist?, ->(*) { false }) do
      assert_enqueued_with(job: FinalizeJobLogJob) { FinalizeJobLogJob.perform_now(@job.id) }
      assert_raises(FinalizeJobLogJob::StorageError) do
        FinalizeJobLogJob.new(@job.id).tap { |j| j.exception_executions = { [FinalizeJobLogJob::StorageError].to_s => 9 } }.perform_now
      end
    end
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
    }) { FinalizeJobLogJob.perform_now(@job.id) }
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
    }) { FinalizeJobLogJob.perform_now(@job.id) }
    assert_equal [0, 1, 2], @job.log_chunks.order(:seq).pluck(:seq)
    assert_not @job.log_complete?
    FinalizeJobLogJob.perform_now(@job.id)
    assert_equal "first\nsecond\nlate\n", @job.reload.log_blob.download
  end
end
