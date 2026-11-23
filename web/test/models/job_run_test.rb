# frozen_string_literal: true

require "test_helper"

class JobRunTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  def build_job(status: "pending")
    project = Project.create!(name: "p")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
    wf.job_runs.create!(name: "build", executor: { "type" => "docker" }, status: status)
  end

  # --- legal transitions ----------------------------------------------------

  test "attempt tokens rotate on claim and clear on release completion cancel stale recovery and rerun" do
    job = build_job
    job.mark_queued!
    job.mark_claimed!(claimed_by: "runner")
    first = job.attempt_token
    assert_match(/\A[0-9a-f-]{36}\z/, first)
    job.mark_running!
    assert_equal first, job.reload.attempt_token
    job.release!
    assert_nil job.reload.attempt_token
    job.mark_claimed!(claimed_by: "runner")
    assert_not_equal first, job.attempt_token
    job.cancel!
    assert_nil job.reload.attempt_token
    job.update_column(:attempt_token, "legacy-leftover")
    job.reset_for_rerun!
    assert_nil job.reload.attempt_token

    %w[success failed canceled].each do |status|
      job = build_job(status: "queued")
      job.mark_claimed!(claimed_by: "runner")
      assert_not_nil job.attempt_token
      job.complete_with_results!(status: status)
      assert_nil job.reload.attempt_token
    end

    %w[claimed running].each do |status|
      job = build_job(status: "queued")
      job.mark_claimed!(claimed_by: "runner")
      job.mark_running! if status == "running"
      job.update_column(:heartbeat_at, 5.minutes.ago)
      job.reclaim_stale!
      assert_equal status == "claimed" ? "queued" : "failed", job.reload.status
      assert_nil job.attempt_token
    end
  end

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

  test "cancellation leaves jobs completed since selection alone and can be repeated" do
    job = build_job(status: "running")
    JobRun.find(job.id).complete_with_results!(status: "success")
    job.cancel!
    assert job.reload.success?

    job = build_job(status: "queued")
    job.cancel!
    job.cancel!
    assert job.reload.canceled?
  end

  test "unblocking skips dependents already queued or canceled since selection" do
    %w[queued canceled].each do |status|
      job = build_job(status: "success")
      dependent = job.workflow_run.job_runs.create!(name: "deploy", requires: [job.name],
                                                    executor: { "type" => "docker" })
      pending_snapshot(job, dependent)
      JobRun.find(dependent.id).update!(status: status)

      job.send(:unblock_dependents!)

      assert_equal status, dependent.reload.status
    end
  end

  test "unblocking does not lock dependents whose requirements are unsatisfied" do
    job = build_job(status: "success")
    dependent = job.workflow_run.job_runs.create!(name: "deploy", requires: ["unfinished"],
                                                  executor: { "type" => "docker" })
    pending_snapshot(job, dependent)
    dependent.define_singleton_method(:with_lock) { raise "locked an unready dependent" }

    job.send(:unblock_dependents!)

    assert dependent.reload.pending?
  end

  test "unreachable cascade skips dependents already moved since selection" do
    %w[queued canceled].each do |status|
      job = build_job(status: "failed")
      dependent = job.workflow_run.job_runs.create!(name: "deploy", requires: [job.name],
                                                    executor: { "type" => "docker" })
      pending_snapshot(job, dependent)
      JobRun.find(dependent.id).update!(status: status)

      job.send(:cancel_unreachable_dependents!)

      assert_equal status, dependent.reload.status
    end
  end

  test "rerun reset leaves jobs already reset or started since selection alone" do
    %w[pending queued claimed running].each do |status|
      job = build_job(status: "failed")
      step = job.step_runs.create!(name: "run", status: "success", exit_code: 0)
      job.log_chunks.create!(seq: 0, chunk: "new attempt output\n")
      JobRun.find(job.id).update!(status: status, claimed_by: "new-runner")

      assert_equal false, job.reset_for_rerun!
      assert_equal status, job.reload.status
      assert_equal "new-runner", job.claimed_by
      assert step.reload.success?
      assert_equal "new attempt output\n", job.log_text
    end
  end

  def pending_snapshot(job, dependent)
    snapshot = [dependent]
    snapshot.define_singleton_method(:find_each) { |&block| each(&block) }
    fresh = JobRun.where(workflow_run_id: job.workflow_run_id).pending
    selected = false
    job.workflow_run.job_runs.define_singleton_method(:pending) do
      if selected
        fresh
      else
        selected = true
        snapshot
      end
    end
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

  # --- release ----------------------------------------------------------------

  test "release! puts a running job back in the queue as if never run" do
    job = build_job(status: "running")
    job.update_columns(claimed_by: "spot-runner", claimed_at: 1.minute.ago, heartbeat_at: Time.current)
    job.step_runs.create!(name: "test", status: "failed", exit_code: 130, started_at: 1.minute.ago, finished_at: Time.current)
    job.log_chunks.create!(seq: 0, chunk: "running tests...\n")
    job.artifacts.create!(path: "coverage.html", storage_key: "k")

    assert job.release!(reason: "runner shutting down (SIGTERM)")

    job.reload
    assert job.queued?
    assert_nil job.claimed_by
    assert_nil job.claimed_at
    assert_nil job.heartbeat_at
    assert_equal 1, job.releases
    step = job.step_runs.sole
    assert step.pending?
    assert_nil step.exit_code
    assert_nil step.started_at
    assert_empty job.log_chunks
    assert_empty job.artifacts
    assert_equal "running", job.workflow_run.reload.status
    assert_equal "running", job.workflow_run.pipeline.reload.status
  end

  test "release! works from claimed too" do
    job = build_job(status: "claimed")
    assert job.release!
    assert job.reload.queued?
  end

  test "release! returns false and changes nothing at the limit" do
    job = build_job(status: "running")
    job.update_columns(releases: JobRun::MAX_RELEASES, claimed_by: "spot-runner")
    job.log_chunks.create!(seq: 0, chunk: "half done\n")

    assert_equal false, job.release!(reason: "again")

    job.reload
    assert job.running?
    assert_equal "spot-runner", job.claimed_by
    assert_equal JobRun::MAX_RELEASES, job.releases
    assert_equal "half done\n", job.log_text
  end

  test "release! from a queued or finished job raises" do
    %w[queued pending success failed canceled].each do |status|
      job = build_job(status: status)
      job.update_column(:name, "build-#{status}")
      assert_raises(JobRun::IllegalTransition, status) { job.release! }
    end
  end

  # --- reclaim -----------------------------------------------------------------

  test "reclaim leaves a claim that started after the stale scan alone" do
    job = build_job(status: "claimed")
    job.update_columns(claimed_by: "runner-1", heartbeat_at: 5.minutes.ago)
    JobRun.find(job.id).mark_running!

    job.reclaim_stale!

    assert job.reload.running?
    assert_equal "runner-1", job.claimed_by
    assert_empty job.log_chunks
  end

  test "reclaim leaves claims and running jobs with refreshed heartbeats alone" do
    %w[claimed running].each do |status|
      job = build_job(status: status)
      job.update_columns(claimed_by: "runner-1", heartbeat_at: 5.minutes.ago)
      heartbeat = Time.current
      JobRun.find(job.id).update!(heartbeat_at: heartbeat)

      job.reclaim_stale!

      assert_equal status, job.reload.status
      assert_in_delta heartbeat.to_f, job.heartbeat_at.to_f, 0.001
      assert_equal "runner-1", job.claimed_by
      assert_empty job.log_chunks
    end
  end

  test "reclaim leaves a running job completed after the stale scan alone" do
    job = build_job(status: "running")
    job.update_columns(heartbeat_at: 5.minutes.ago)
    job.log_chunks.create!(seq: 0, chunk: "finished successfully\n")
    JobRun.find(job.id).complete_with_results!(status: "success")

    job.reclaim_stale!

    assert job.reload.success?
    assert_equal "finished successfully\n", job.log_text
    assert job.workflow_run.reload.success?
  end

  test "reclaim ignores jobs without a stale active heartbeat" do
    %w[pending queued success failed canceled claimed running].each do |status|
      job = build_job(status: status)
      job.reclaim_stale!
      assert_equal status, job.reload.status
      assert_empty job.log_chunks
    end
  end

  test "reclaim only acts strictly before the supplied cutoff" do
    cutoff = 1.minute.ago.change(usec: 0)
    job = build_job(status: "claimed")
    job.update_columns(heartbeat_at: cutoff)
    job.reclaim_stale!(cutoff: cutoff)
    assert job.reload.claimed?

    JobRun.reclaim_stale!(older_than: 30.seconds)
    assert job.reload.queued?
  end

  test "stale release instances honor the persisted release limit" do
    job = build_job(status: "running")
    JobRun.find(job.id).update!(releases: JobRun::MAX_RELEASES)

    assert_equal false, job.release!
    assert job.reload.running?
    assert_equal JobRun::MAX_RELEASES, job.releases
  end

  test "stale lifecycle instances cannot overwrite newer persisted states" do
    %i[mark_running! release! complete_with_results!].each do |operation|
      job = build_job(status: "claimed")
      JobRun.find(job.id).complete_with_results!(status: "success")

      assert_raises(JobRun::IllegalTransition, operation.to_s) do
        operation == :complete_with_results! ? job.complete_with_results!(status: "failed") : job.public_send(operation)
      end
      assert job.reload.success?
    end
  end

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
    JobRun.define_method(:reclaim_stale!) { |**kwargs| id == failing ? raise("boom") : orig_reclaim(**kwargs) }
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
    perform_enqueued_jobs { job.transition_to!("success") }
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
