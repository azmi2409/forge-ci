# frozen_string_literal: true

require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "acme/web", max_concurrency: 4)
    @pipeline = PipelineIntake.call!(project: @project, sha: "abc123", branch: "main", ir: compile_test_ir)
    sign_in_as("dev", role: :member)
  end

  test "a running pipeline offers cancel, not rerun" do
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_response :ok
    assert_select "form[action$='/cancel']"
    assert_select "form[action*='/rerun']", count: 0

    post "/projects/#{@project.id}/pipelines/#{@pipeline.id}/rerun"
    assert_redirected_to "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_match "Wait for the pipeline to finish", flash[:alert]
  end

  test "a canceled pipeline offers both reruns, and rerunning failed jobs queues them again" do
    @pipeline.cancel!
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_select "form[action*='/rerun?scope=failed']"
    assert_select "form[action*='/rerun?scope=all']"

    post "/projects/#{@project.id}/pipelines/#{@pipeline.id}/rerun", params: { scope: "failed" }
    assert_match "Rerunning 3 jobs that failed", flash[:notice]
    assert @pipeline.reload.running?
    assert_equal %w[pending pending queued], @pipeline.job_runs.map(&:status).sort
  end

  test "the job page shows a finished job's non-ASCII log" do
    job = @pipeline.job_runs.find_by!(name: "build")
    job.mark_claimed!(claimed_by: "r")
    job.mark_running!
    job.log_chunks.create!(seq: 0, chunk: "✓ selesai — ünïcode\n")
    job.complete_with_results!(status: "success")

    get "/job_runs/#{job.id}"
    assert_response :ok
    assert_includes response.body, "✓ selesai — ünïcode"
  end

  test "workflow diagram serializes grouped jobs and dependency edges with fallback" do
    build = @pipeline.job_runs.find_by!(name: "build")
    build.update!(status: :success)
    job = @pipeline.job_runs.find_by!(name: "test")
    job.update!(parallelism: 2, status: :running)
    copy = job.dup
    copy.update!(node_index: 1, status: :success)

    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_response :ok
    assert_select "[data-workflow-diagram]" do |elements|
      graph = JSON.parse(elements.first["data-workflow-diagram"])
      assert_equal %w[build test deploy], graph["nodes"].map { |node| node["id"] }
      data = graph["nodes"][1]["data"]
      assert_equal "running", data["status"]
      assert_equal "medium", data["resource_class"]
      assert_equal 2, data["parallel"]
      assert_equal %w[running success], data["nodes"].map { |node| node["status"] }
      assert_equal "/job_runs/#{job.id}", data["href"]
      assert_equal ["build"], data["requires"]
      assert_equal 1, data["stage"]
      assert_equal [["build", "test"], ["test", "deploy"]], graph["edges"].map { |edge| edge.values_at("source", "target") }
      assert_equal "success", graph["edges"][0]["data"]["status"]
      assert_equal "default", graph["edges"][0]["type"]
      assert_equal "build", graph["edges"][0]["targetHandle"]
      assert_equal 840, graph["width"]
      assert_equal 124, graph["height"]
      assert graph["edges"][0]["animated"]
      assert_not graph["edges"][1]["animated"]
    end
    assert_select ".graph .jobnode", count: 3
    assert_select "meta[http-equiv=refresh][content='5']"
  end

  test "workflow diagram distinguishes dependencies that skip a stage" do
    @pipeline.job_runs.find_by!(name: "deploy").update!(requires: %w[build test])
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    graph = JSON.parse(css_select("[data-workflow-diagram]").first["data-workflow-diagram"])
    assert_equal ["build"], graph["nodes"].last["data"]["long_requires"]
    assert_equal 3, graph["edges"].size
  end

  test "workflow diagram handles empty workflows and unknown dependencies" do
    @pipeline.workflow_runs.each { |workflow| workflow.job_runs.destroy_all }
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    graph = JSON.parse(css_select("[data-workflow-diagram]").first["data-workflow-diagram"])
    assert_empty graph["nodes"]
    assert_empty graph["edges"]
    assert_equal 0, graph["width"]
    assert_equal 0, graph["height"]

    @pipeline.workflow_runs.first.job_runs.create!(name: "orphan <job>", requires: ["missing"], status: :failed)
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    graph = JSON.parse(css_select("[data-workflow-diagram]").first["data-workflow-diagram"])
    assert_equal "orphan <job>", graph["nodes"].first["data"]["name"]
    assert_equal "failed", graph["nodes"].first["data"]["status"]
    assert_empty graph["edges"]
  end
end
