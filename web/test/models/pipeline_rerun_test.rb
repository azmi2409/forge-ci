# frozen_string_literal: true

require "test_helper"

class PipelineRerunTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(name: "p", max_concurrency: 8)
    @pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    @wf = @pipeline.workflow_runs.create!(name: "checks", status: "running")
    @lint = job("lint")
    @tests = 2.times.map { |i| job("test", parallelism: 2, node_index: i) }
    @deploy = job("deploy", requires: %w[lint test])
  end

  def job(name, requires: [], parallelism: 1, node_index: 0)
    j = @wf.job_runs.create!(name: name, executor: { "type" => "docker" }, requires: requires, steps: [],
                             parallelism: parallelism, node_index: node_index)
    j.step_runs.create!(name: "run", status: "pending")
    j
  end

  def run!(job, status)
    job.mark_queued! if job.pending?
    job.mark_claimed!(claimed_by: "r")
    job.mark_running!
    job.log_chunks.create!(seq: 0, chunk: "output\n")
    job.complete_with_results!(status: status, step_results: [{ name: "run", exit_code: status == "success" ? 0 : 1 }])
  end

  test "rerun failed resets every node of the failed job and its canceled dependents, keeps the rest" do
    run!(@lint, "success")
    run!(@tests[0], "failed") # cancels node 1 and the unreachable deploy
    assert @pipeline.reload.failed?

    assert_equal 3, @pipeline.rerun!
    assert @lint.reload.success?, "succeeded jobs are kept"
    assert_equal %w[queued queued], @tests.map { |t| t.reload.status }
    assert @deploy.reload.pending?, "waits for test again"
    assert_equal 0, @tests[0].log_chunks.count
    assert_equal ["pending"], @tests[0].step_runs.pluck(:status)
    assert_nil @tests[0].claimed_by
    assert @pipeline.reload.running?
    assert @wf.reload.running?

    @tests.each { |t| run!(t, "success") }
    assert @deploy.reload.queued?, "the rerun unblocks dependents as usual"
  end

  test "rerun all resets every job and queues only those with nothing to wait for" do
    run!(@lint, "success")
    @tests.each { |t| run!(t, "success") }
    run!(@deploy, "success")
    assert @pipeline.reload.success?

    assert_equal 4, @pipeline.rerun!(only_failed: false)
    assert_equal %w[queued queued queued pending], [@lint, *@tests, @deploy].map { |j| j.reload.status }
  end

  test "a pipeline that is still running can't be rerun" do
    assert_raises(ArgumentError) { @pipeline.rerun! }
  end
end
