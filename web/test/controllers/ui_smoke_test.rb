# frozen_string_literal: true

require "test_helper"

# Smoke tests for the server-rendered UI (basic auth + ERB render).
class UiSmokeTest < ActionDispatch::IntegrationTest
  setup do
    project = Project.create!(name: "demo", repo_url: "https://example.com/demo", max_concurrency: 4)
    post "/api/v1/projects/#{project.id}/pipelines",
         params: { sha: "abc123def", branch: "main", ir: compile_test_ir }, headers: admin_headers, as: :json
    assert_response :created
    @pipeline_id = json_body["id"]
    @project_id = project.id
    @job_id = Pipeline.find(@pipeline_id).job_runs.find_by!(name: "build").id
  end

  test "UI requires login" do
    get "/projects"
    assert_redirected_to "/login"
  end

  test "landing page is public" do
    get "/"
    assert_response :ok
    assert_match "ForgeCI", response.body
    assert_match "CircleCI", response.body
  end

  test "dashboard redirects to projects" do
    get "/dashboard"
    assert_redirected_to "/projects"
  end

  test "projects index renders" do
    sign_in_as_admin
    get "/projects"
    assert_response :ok
    assert_match "demo", response.body
  end

  test "pipeline show renders workflows, jobs and requires edges" do
    sign_in_as_admin
    get "/projects/#{@project_id}/pipelines/#{@pipeline_id}"
    assert_response :ok
    assert_match "build-test-deploy", response.body
    assert_match "build", response.body
    # requires edges are visible (test requires build)
    assert_match "requires", response.body.downcase
  end

  test "landing page names the real config path" do
    get "/"
    assert_match ".circleci/config.yml", response.body
    assert_no_match ".forge-ci/config.yml", response.body
  end

  test "dashboard shows stats, project cards and recent pipelines" do
    sign_in_as_admin
    get "/projects"
    assert_response :ok
    assert_match "Running now", response.body
    assert_match %(href="/projects/#{@project_id}"), response.body
    assert_match %(href="/projects/#{@project_id}/pipelines/#{@pipeline_id}"), response.body
  end

  test "project show lists its pipelines" do
    sign_in_as_admin
    get "/projects/#{@project_id}"
    assert_response :ok
    assert_match "demo", response.body
    assert_match %(href="/projects/#{@project_id}/pipelines/#{@pipeline_id}"), response.body
  end

  test "project show requires login" do
    get "/projects/#{@project_id}"
    assert_redirected_to "/login"
  end

  test "pipeline graph puts each job in the stage after what it requires" do
    sign_in_as_admin
    get "/projects/#{@project_id}/pipelines/#{@pipeline_id}"
    stages = css_select(".stage").map { |st| css_select(st, ".jobnode-name").map { |n| n.text.strip } }
    assert_equal [["build"], ["test"], ["deploy"]], stages
  end

  test "job show renders steps and log viewer" do
    sign_in_as_admin
    get "/job_runs/#{@job_id}"
    assert_response :ok
    assert_match "Install dependencies", response.body
  end
end
