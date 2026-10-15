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
             params: intake_params, as: :json
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
         params: intake_params(contexts: ["deploy"]), as: :json
    assert_response :created

    pipeline = Pipeline.find(json_body["id"])
    pipeline.job_runs.each do |job|
      assert_equal({ "DEPLOY_KEY" => "s3cr3t", "SHARED" => "from-context" }, job.context_environment)
    end
  end

  test "executor environment merged with contexts, contexts win" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: intake_params(contexts: ["deploy"]), as: :json
    build = Pipeline.find(json_body["id"]).job_runs.find_by(name: "build")
    # executor env has RAILS_ENV=test; context adds DEPLOY_KEY/SHARED
    assert_equal "test", build.merged_environment["RAILS_ENV"]
    assert_equal "s3cr3t", build.merged_environment["DEPLOY_KEY"]
  end

  test "unknown context name returns 404" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: intake_params(contexts: ["nope"]), as: :json
    assert_response :not_found
    assert_match "nope", json_body["error"]
  end

  test "invalid IR returns 422 with details" do
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: { "workflows" => [] } }, as: :json
    assert_response :unprocessable_entity
    assert_not_empty json_body["details"]
  end

  test "missing project returns 404" do
    post "/api/v1/projects/999999/pipelines", params: intake_params, as: :json
    assert_response :not_found
  end
end
