# frozen_string_literal: true

require "test_helper"

class Api::V1::PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", repo_url: "https://example.com/demo", max_concurrency: 4)
    @project.contexts.create!(name: "deploy", payload: { "DEPLOY_KEY" => "s3cr3t", "SHARED" => "from-context" })
  end

  def intake_params(overrides = {})
    { sha: "abc123", branch: "main", ir: compile_test_ir }.merge(overrides)
  end

  test "creates pipeline, workflows, jobs and steps from a real compiler IR" do
    assert_difference %w[Pipeline.count WorkflowRun.count], 1 do
      assert_difference %w[JobRun.count], 3 do
        post "/api/v1/projects/#{@project.id}/pipelines",
             params: intake_params, headers: admin_headers, as: :json
      end
    end

    assert_response :created
    body = json_body
    assert_equal "running", body["status"]
    assert_equal 1, body["workflows"].size

    jobs = body["workflows"].first["jobs"]
    by_name = jobs.index_by { |j| j["name"] }
    assert_equal %w[build deploy test].sort, by_name.keys.sort
    assert_equal "queued", by_name["build"]["status"], "requires-empty job starts queued"
    assert_equal "pending", by_name["test"]["status"]
    assert_equal "pending", by_name["deploy"]["status"]
    assert_equal [], by_name["build"]["requires"]
    assert_equal ["build"], by_name["test"]["requires"]
    assert_equal ["test"], by_name["deploy"]["requires"]

    build = JobRun.find(by_name["build"]["id"])
    assert_equal 2, build.step_runs.count
    assert_equal "medium", build.resource_class
    assert_equal "cimg/ruby:3.2", build.executor["image"]
    assert_equal "#{@project.id}/build-test-deploy/build", build.concurrency_key
  end

  test "resolves named contexts and merges their payloads into jobs" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: intake_params(contexts: ["deploy"]), headers: admin_headers, as: :json
    assert_response :created

    pipeline = Pipeline.find(json_body["id"])
    pipeline.job_runs.each do |job|
      assert_equal({ "DEPLOY_KEY" => "s3cr3t", "SHARED" => "from-context" }, job.context_environment)
    end
  end

  test "executor environment merged with contexts, contexts win" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: intake_params(contexts: ["deploy"]), headers: admin_headers, as: :json
    build = Pipeline.find(json_body["id"]).job_runs.find_by(name: "build")
    # executor env has RAILS_ENV=test; context adds DEPLOY_KEY/SHARED
    assert_equal "test", build.merged_environment["RAILS_ENV"]
    assert_equal "s3cr3t", build.merged_environment["DEPLOY_KEY"]
  end

  test "unknown context name returns 404" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: intake_params(contexts: ["nope"]), headers: admin_headers, as: :json
    assert_response :not_found
    assert_match "nope", json_body["error"]
  end

  test "invalid IR returns 422 with details" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: { "workflows" => [] } }, headers: admin_headers, as: :json
    assert_response :unprocessable_entity
    assert_not_empty json_body["details"]
  end

  test "lists newest project pipelines as summaries without secrets or workflows" do
    pipeline = PipelineIntake.call!(project: @project, **intake_params, context_names: ["deploy"])
    newer = @project.pipelines.create!(sha: "def456", branch: "feature", status: :success, created_at: 1.day.ago)
    other_project = Project.create!(name: "other")
    other_project.pipelines.create!(sha: "other", branch: "main")

    get "/api/v1/projects/#{@project.id}/pipelines", headers: admin_headers

    assert_response :ok
    assert_equal ["pipelines"], json_body.keys
    assert_equal [newer.id, pipeline.id], json_body["pipelines"].map { |item| item["id"] }
    assert_equal({ "id" => newer.id, "project_id" => @project.id, "sha" => "def456",
                   "branch" => "feature", "status" => "success" }, json_body["pipelines"].first)
    json_body["pipelines"].each do |item|
      assert_equal %w[branch id project_id sha status], item.keys.sort
    end
    assert_not_includes response.body, "s3cr3t"
    assert_not_includes response.body, "DEPLOY_KEY"

    get "/api/v1/pipelines/#{pipeline.id}", headers: admin_headers
    assert_response :ok
    assert_equal 1, json_body["workflows"].size, "detail endpoint keeps workflows"
  end

  test "filters branch and sha by exact equality and combines both" do
    match = @project.pipelines.create!(sha: "abc%_", branch: "feature/%_")
    same_branch = @project.pipelines.create!(sha: "other", branch: match.branch)
    same_sha = @project.pipelines.create!(sha: match.sha, branch: "other")
    @project.pipelines.create!(sha: "abc12", branch: "feature/12")

    [
      [{ branch: match.branch }, [same_branch.id, match.id]],
      [{ sha: match.sha }, [same_sha.id, match.id]],
      [{ branch: match.branch, sha: match.sha }, [match.id]],
      [{ branch: "missing" }, []],
      [{ branch: "" }, []],
      [{ sha: "" }, []]
    ].each do |filters, ids|
      get "/api/v1/projects/#{@project.id}/pipelines", params: filters, headers: admin_headers
      assert_response :ok
      assert_equal ids, json_body["pipelines"].map { |item| item["id"] }
    end
  end

  test "defaults to twenty recent pipelines and accepts limits one through one hundred" do
    ids = 101.times.map { |i| @project.pipelines.create!(sha: "sha#{i}", branch: "main").id }.reverse

    [nil, 1, 100].each do |limit|
      get "/api/v1/projects/#{@project.id}/pipelines", params: limit ? { limit: limit } : {}, headers: admin_headers
      assert_response :ok
      assert_equal ids.first(limit || 20), json_body["pipelines"].map { |item| item["id"] }
    end
  end

  test "rejects invalid limits and non scalar filters" do
    invalid = [
      { limit: "0" }, { limit: "-1" }, { limit: "101" }, { limit: "1.5" },
      { limit: "1junk" }, { limit: "" }, { limit: " 1" }, { limit: "+1" },
      { limit: ["1"] }, { limit: { value: "1" } },
      { branch: ["main"] }, { branch: { value: "main" } },
      { sha: ["abc"] }, { sha: { value: "abc" } }
    ]
    invalid.each do |filters|
      get "/api/v1/projects/#{@project.id}/pipelines", params: filters, headers: admin_headers
      assert_response :bad_request, filters.inspect
      assert json_body["error"].present?
    end

    [{ limit: nil }, { limit: true }, { limit: 1.5 }, { branch: nil }, { branch: 1 },
     { branch: false }, { sha: nil }, { sha: 1 }, { sha: false }].each do |filters|
      get "/api/v1/projects/#{@project.id}/pipelines", params: filters, headers: admin_headers, as: :json
      assert_response :bad_request, filters.inspect
    end
  end

  test "listing requires API authentication and rejects runner tokens" do
    [nil, "wrong", RunnerToken.generate!(name: "runner").last].each do |token|
      get "/api/v1/projects/#{@project.id}/pipelines", headers: token ? bearer_headers(token) : {}
      assert_response :unauthorized
    end
  end

  test "listing an empty project succeeds and missing project returns 404" do
    get "/api/v1/projects/#{@project.id}/pipelines", headers: admin_headers
    assert_response :ok
    assert_equal({ "pipelines" => [] }, json_body)

    get "/api/v1/projects/999999/pipelines", headers: admin_headers
    assert_response :not_found
    assert_equal "project not found", json_body["error"]
  end

  test "missing project returns 404" do
    post "/api/v1/projects/999999/pipelines", params: intake_params, headers: admin_headers, as: :json
    assert_response :not_found
  end
end
