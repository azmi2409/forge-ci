# frozen_string_literal: true

require "test_helper"

class PipelineParallelismTest < ActiveSupport::TestCase
  CONFIG = <<~YAML
    version: 2.1
    jobs:
      test:
        docker: [{ image: cimg/ruby:3.3 }]
        parallelism: 3
        steps:
          - checkout
          - run: bin/rails test
      deploy:
        docker: [{ image: cimg/ruby:3.3 }]
        steps:
          - run: ./deploy.sh
    workflows:
      ci:
        jobs:
          - test
          - deploy:
              requires: [test]
  YAML

  setup do
    @project = Project.create!(name: "par", max_concurrency: 10)
    ir, errors = ForgeCI::Compiler.compile(CONFIG, pipeline_params: { "branch" => "main" })
    assert_empty errors
    @pipeline = PipelineIntake.call!(project: @project, sha: "abc", branch: "main",
                                     ir: ::JSON.parse(ir.to_json))
  end

  def nodes
    @pipeline.job_runs.where(name: "test").order(:node_index).to_a
  end

  def deploy
    @pipeline.job_runs.find_by!(name: "deploy")
  end

  def finish(job, status)
    job.mark_claimed!(claimed_by: "r")
    job.mark_running!
    job.complete_with_results!(status: status, step_results: [])
  end

  test "parallelism creates one queued job run per node" do
    assert_equal [0, 1, 2], nodes.map(&:node_index)
    assert nodes.all? { |j| j.parallelism == 3 && j.queued? }
    assert nodes.all? { |j| j.step_runs.count == 2 }
    assert_equal ["test [1/3]", "test [2/3]", "test [3/3]"], nodes.map(&:display_name)
    assert_equal 1, deploy.parallelism
    assert_equal "deploy", deploy.display_name
  end

  test "dependents wait for every node to succeed" do
    finish(nodes[0], "success")
    finish(nodes[1], "success")
    assert deploy.reload.pending?, "deploy must wait for the last node"

    finish(nodes[2], "success")
    assert deploy.reload.queued?
  end

  test "one failed node cancels dependents" do
    finish(nodes[0], "success")
    finish(nodes[1], "failed")
    assert deploy.reload.canceled?
  end
end
