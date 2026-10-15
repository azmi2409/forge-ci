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

  test "reclaim is idempotent" do
    stale = build_job(status: "claimed")
    stale.update_columns(heartbeat_at: 5.minutes.ago)
    JobRun.reclaim_stale!
    JobRun.reclaim_stale!
    assert_equal "queued", stale.reload.status
  end
end
