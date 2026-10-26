# frozen_string_literal: true

require "test_helper"

class RunnerInstanceTest < ActiveSupport::TestCase
  setup do
    @token, = RunnerToken.generate!(name: "presence-model")
    @runner = @token.runner_instances.create!(uuid: SecureRandom.uuid, hostname: "worker", implementation: "go",
                                             last_seen_at: Time.current)
  end

  test "freshness boundary is exactly 120 seconds" do
    seen = @runner.last_seen_at
    assert_equal "idle", @runner.status(now: seen + 119.seconds)
    assert_equal "offline", @runner.status(now: seen + 120.seconds)
    assert_equal "offline", @runner.status(now: seen + 121.seconds)
  end

  test "busy requires fresh presence and an active token-owned job" do
    project = Project.create!(name: "runner-status")
    pipeline = PipelineIntake.call!(project: project, sha: "status", branch: "main", ir: compile_test_ir)
    job = pipeline.job_runs.first
    job.update!(status: :claimed, claimed_by: @token.name)
    @runner.update!(current_job_run: job)
    now = @runner.last_seen_at
    assert_equal "busy", @runner.status(now: now)
    assert_equal "offline", @runner.status(now: now + 120.seconds)
    %w[success failed canceled queued].each do |status|
      job.update!(status: status)
      @runner.reload
      assert_equal "idle", @runner.status(now: now), status
      assert_nil @runner.active_job
    end
    job.update!(status: :running, claimed_by: "another-token")
    assert_equal "idle", @runner.reload.status(now: now)
  end

  test "identity uniqueness is token scoped and token deletion removes instances" do
    assert_raises ActiveRecord::RecordNotUnique do
      @token.runner_instances.create!(uuid: @runner.uuid, hostname: "duplicate", implementation: "go", last_seen_at: Time.current)
    end
    other, = RunnerToken.generate!(name: "another-presence-model")
    other.runner_instances.create!(uuid: @runner.uuid, hostname: "other", implementation: "ruby", last_seen_at: Time.current)
    @token.destroy!
    assert_not RunnerInstance.exists?(@runner.id)
    assert_equal 1, other.runner_instances.count
  end

  test "deleting a job clears its presence reference" do
    project = Project.create!(name: "runner-deletion")
    pipeline = PipelineIntake.call!(project: project, sha: "delete", branch: "main", ir: compile_test_ir)
    job = pipeline.job_runs.first
    @runner.update!(current_job_run: job)
    job.destroy!
    assert_nil @runner.reload.current_job_run_id
  end
end
