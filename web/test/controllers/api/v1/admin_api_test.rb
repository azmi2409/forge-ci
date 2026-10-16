# frozen_string_literal: true

require "test_helper"

class Api::V1::AdminApiTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
  end

  def start_pipeline
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir }, headers: admin_headers, as: :json
    assert_response :created
    Pipeline.find(json_body["id"])
  end

  test "pipeline intake requires the admin token" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir }, as: :json
    assert_response :unauthorized

    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir },
         headers: { "Authorization" => "Bearer wrong" }, as: :json
    assert_response :unauthorized
    assert_equal 0, Pipeline.count
  end

  test "intake is fail-closed when no admin token is configured" do
    ENV["FORGE_CI_ADMIN_TOKEN"] = nil
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir }, as: :json
    assert_response :service_unavailable
  ensure
    ENV["FORGE_CI_ADMIN_TOKEN"] = TEST_ADMIN_TOKEN
  end

  test "a runner token cannot use the admin API" do
    _rec, raw = RunnerToken.generate!(name: "r1")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir }, headers: bearer_headers(raw), as: :json
    assert_response :unauthorized
  end

  test "projects can be created and listed" do
    post "/api/v1/projects", params: { name: "api-made", repo_url: "https://github.com/o/r.git" },
                             headers: admin_headers, as: :json
    assert_response :created
    assert_equal 4, json_body["max_concurrency"]

    post "/api/v1/projects", params: { name: "api-made" }, headers: admin_headers, as: :json
    assert_response :unprocessable_entity
    post "/api/v1/projects", params: { repo_url: "x" }, headers: admin_headers, as: :json
    assert_response :unprocessable_entity

    get "/api/v1/projects", headers: admin_headers
    assert_response :ok
    assert_includes json_body["projects"].map { |p| p["name"] }, "api-made"

    get "/api/v1/projects"
    assert_response :unauthorized
  end

  test "pipeline show reports status" do
    pipeline = start_pipeline
    get "/api/v1/pipelines/#{pipeline.id}", headers: admin_headers
    assert_response :ok
    assert_equal "running", json_body["status"]
    get "/api/v1/pipelines/999999", headers: admin_headers
    assert_response :not_found
  end

  test "cancel cancels queued, pending and running jobs and the pipeline" do
    pipeline = start_pipeline
    build = pipeline.job_runs.find_by!(name: "build")
    build.mark_claimed!(claimed_by: "r1")
    build.mark_running!

    post "/api/v1/pipelines/#{pipeline.id}/cancel", headers: admin_headers
    assert_response :ok
    assert_equal "canceled", json_body["status"]
    assert pipeline.job_runs.reload.all?(&:canceled?)
    assert_equal "canceled", pipeline.workflow_runs.sole.reload.status
  end

  test "cancel leaves finished jobs alone and is idempotent" do
    pipeline = start_pipeline
    build = pipeline.job_runs.find_by!(name: "build")
    build.mark_claimed!(claimed_by: "r1")
    build.complete_with_results!(status: "success")

    2.times do
      post "/api/v1/pipelines/#{pipeline.id}/cancel", headers: admin_headers
      assert_response :ok
    end
    assert build.reload.success?
    assert_equal "canceled", pipeline.reload.status
  end

  test "heartbeat on a canceled job reports canceled so the runner can stop" do
    pipeline = start_pipeline
    _rec, raw = RunnerToken.generate!(name: "r1", resource_class: "medium")
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(raw)
    job_id = json_body["id"]
    post "/api/v1/pipelines/#{pipeline.id}/cancel", headers: admin_headers

    post "/api/v1/runner/jobs/#{job_id}/heartbeat", headers: bearer_headers(raw)
    assert_response :ok
    assert_equal "canceled", json_body["status"]
  end

  test "UI cancel button cancels the pipeline" do
    pipeline = start_pipeline
    post "/projects/#{@project.id}/pipelines/#{pipeline.id}/cancel", headers: ui_basic_auth_headers
    assert_redirected_to "/projects/#{@project.id}/pipelines/#{pipeline.id}"
    assert_equal "canceled", pipeline.reload.status
  end
end
