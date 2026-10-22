# frozen_string_literal: true

require "test_helper"

class WorkflowRunTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(name: "p")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    @wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
  end

  def job(name, requires: [], parallelism: 1, node_index: 0)
    @wf.job_runs.create!(name: name, executor: { "type" => "docker" }, requires: requires,
                         parallelism: parallelism, node_index: node_index)
  end

  test "stages follow the requires graph and group parallel nodes" do
    job("lint")
    2.times { |i| job("test", parallelism: 2, node_index: i) }
    job("build")
    job("deploy", requires: %w[test build])
    job("notify", requires: %w[deploy])

    stages = @wf.reload.stages.map { |stage| stage.map { |nodes| [nodes.first.name, nodes.size] } }
    assert_equal [[["lint", 1], ["test", 2], ["build", 1]], [["deploy", 1]], [["notify", 1]]], stages
  end

  test "requires naming jobs outside the workflow are ignored" do
    job("deploy", requires: %w[filtered-out])
    assert_equal [["deploy"]], @wf.reload.stages.map { |stage| stage.map { |nodes| nodes.first.name } }
  end

  test "a failed node of a parallel job cancels its other nodes, not other jobs" do
    nodes = 3.times.map { |i| job("test", parallelism: 3, node_index: i) }
    lint = job("lint")
    nodes.each(&:mark_queued!)
    lint.mark_queued!
    nodes[0].mark_claimed!(claimed_by: "r1")
    nodes[0].mark_running!
    nodes[1].mark_claimed!(claimed_by: "r2")
    nodes[1].mark_running!

    nodes[0].complete_with_results!(status: "failed")
    assert_equal %w[failed canceled canceled], nodes.map { |n| n.reload.status }
    assert lint.reload.queued?, "other jobs keep going"
  end
end
