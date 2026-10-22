# frozen_string_literal: true

require "test_helper"

class JobRunTest < ActiveSupport::TestCase
  def build_job(status: "pending")
    project = Project.create!(name: "p")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
    wf.job_runs.create!(name: "build", executor: { "type" => "docker" }, status: status)
  end

  # --- legal transitions ----------------------------------------------------

  test "pending -> queued -> claimed -> running -> success is legal" do
    job = build_job
    job.mark_queued!
    assert job.queued?
    job.mark_claimed!(claimed_by: "runner-1")
    assert job.claimed?
    assert_equal "runner-1", job.claimed_by
    assert_not_nil job.claimed_at
    assert_not_nil job.heartbeat_at
    job.mark_running!
    assert job.running?
    job.complete_with_results!(status: "success", step_results: [])
    assert job.success?
  end

  test "claimed -> queued is legal (reclaim path)" do
    job = build_job(status: "claimed")
    job.transition_to!("queued", claimed_by: nil, claimed_at: nil, heartbeat_at: nil)
    assert job.queued?
    assert_nil job.claimed_by
  end

  test "running -> failed and running -> canceled are legal" do
    job = build_job(status: "running")
    job.complete_with_results!(status: "failed", step_results: [])
    assert job.failed?

    job2 = build_job(status: "running")
    job2.complete_with_results!(status: "canceled", step_results: [])
    assert job2.canceled?
  end

  test "queued -> canceled is legal" do
    job = build_job(status: "queued")
    job.cancel!
    assert job.canceled?
  end

  # --- illegal transitions raise ---------------------------------------------

  test "pending -> running raises IllegalTransition" do
    job = build_job
    assert_raises(JobRun::IllegalTransition) { job.mark_running! }
  end

  test "success is terminal: success -> queued raises" do
    job = build_job(status: "success")
    assert_raises(JobRun::IllegalTransition) { job.mark_queued! }
  end

  test "complete with a non-terminal status raises" do
    job = build_job(status: "running")
    assert_raises(JobRun::IllegalTransition) { job.complete_with_results!(status: "bogus") }
  end

  test "complete from queued raises (must be claimed/running)" do
    job = build_job(status: "queued")
    assert_raises(JobRun::IllegalTransition) { job.complete_with_results!(status: "success") }
  end

  # --- reclaim -----------------------------------------------------------------

  test "reclaim_stale! returns stale claimed/running jobs to queued" do
    stale = build_job(status: "claimed")
    stale.update_columns(claimed_by: "runner-1", claimed_at: 5.minutes.ago, heartbeat_at: 5.minutes.ago)
    fresh = build_job(status: "running")
    fresh.update_columns(claimed_by: "runner-2", claimed_at: 1.minute.ago, heartbeat_at: 30.seconds.ago)
    queued = build_job(status: "queued")

    JobRun.reclaim_stale!

    assert_equal "queued", stale.reload.status
    assert_nil stale.claimed_by
    assert_nil stale.claimed_at
    assert_equal "running", fresh.reload.status
    assert_equal "queued", queued.reload.status
  end

  test "reclaim_stale! fails a stale running job with a note, and keeps going after an error" do
    job = build_job(status: "running")
    job.update_columns(claimed_by: "static-runner", claimed_at: 10.minutes.ago, heartbeat_at: 5.minutes.ago)
    job.step_runs.create!(name: "deploy", status: "running")
    job.log_chunks.create!(seq: 0, chunk: "deploying...\n")
    claimed = build_job(status: "claimed")
    claimed.update_columns(heartbeat_at: 5.minutes.ago)

    JobRun.reclaim_stale!

    assert job.reload.failed?
    assert_includes job.log_text, "stopped responding while this job was running"
    assert_equal ["canceled"], job.step_runs.pluck(:status)
    assert job.workflow_run.pipeline.reload.failed?, "the pipeline rolls up instead of hanging"
    assert claimed.reload.queued?
  end

  test "one job that can't be reclaimed doesn't stop the others" do
    a = build_job(status: "claimed")
    b = build_job(status: "claimed")
    [a, b].each { |j| j.update_columns(heartbeat_at: 5.minutes.ago) }
    failing = a.id
    JobRun.class_eval { alias_method :orig_reclaim, :reclaim_stale! }
    JobRun.define_method(:reclaim_stale!) { id == failing ? raise("boom") : orig_reclaim }
    JobRun.reclaim_stale!
    assert b.reload.queued?
  ensure
    JobRun.class_eval { alias_method :reclaim_stale!, :orig_reclaim; remove_method :orig_reclaim }
  end

  test "reclaim is idempotent" do
    stale = build_job(status: "claimed")
    stale.update_columns(heartbeat_at: 5.minutes.ago)
    JobRun.reclaim_stale!
    JobRun.reclaim_stale!
    assert_equal "queued", stale.reload.status
  end

  test "a finished job's stored log comes back as UTF-8 text, with invalid bytes replaced" do
    job = build_job(status: "running")
    job.log_chunks.create!(seq: 0, chunk: "✓ 12 tests passed — sukses ünïcode\n")
    job.transition_to!("success")
    job.reload
    assert job.log_blob.attached?

    [job.log_text, job.log_chunk_list.first[:chunk]].each do |text|
      assert_equal Encoding::UTF_8, text.encoding
      assert text.valid_encoding?
      assert_includes text, "✓ 12 tests passed — sukses ünïcode"
      assert_includes "#{text}café", "café", "joins with other UTF-8 strings"
    end

    job.log_blob.attach(io: StringIO.new("ok \xFF end".b), filename: "job.log", content_type: "text/plain")
    text = job.reload.log_text
    assert text.valid_encoding?
    assert_equal "ok \uFFFD end", text
  end
end
