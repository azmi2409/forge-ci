# frozen_string_literal: true

require "test_helper"

class Api::V1::JobsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @token_record, @raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir }, as: :json
    assert_response :created
    @pipeline = Pipeline.find(json_body["id"])
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(@raw)
    assert_response :ok
    @job_id = json_body["id"]
  end

  def auth
    bearer_headers(@raw)
  end

  test "log chunks posted out of order come back ordered" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 2, chunk: "third\n" }, headers: auth, as: :json
    assert_response :ok
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "first\n" }, headers: auth, as: :json
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 1, chunk: "second\n" }, headers: auth, as: :json

    get "/api/v1/jobs/#{@job_id}/logs", headers: auth
    assert_response :ok
    chunks = json_body["chunks"]
    assert_equal [0, 1, 2], chunks.map { |c| c["seq"] }
    assert_equal "first\nsecond\nthird\n", chunks.map { |c| c["chunk"] }.join
  end

  test "duplicate seq posts are idempotent (upsert)" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "v1\n" }, headers: auth, as: :json
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "v2\n" }, headers: auth, as: :json
    assert_response :ok

    get "/api/v1/jobs/#{@job_id}/logs", headers: auth
    chunks = json_body["chunks"]
    assert_equal 1, chunks.size
    assert_equal "v2\n", chunks.first["chunk"]
  end

  test "log chunks require seq and chunk" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0 }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "logs endpoints require a valid bearer token" do
    get "/api/v1/jobs/#{@job_id}/logs"
    assert_response :unauthorized
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "x" }, as: :json
    assert_response :unauthorized
  end

  test "a token that did not claim the job gets 403 on logs" do
    _rec, other_raw = RunnerToken.generate!(name: "runner-2", resource_class: "medium")
    get "/api/v1/jobs/#{@job_id}/logs", headers: bearer_headers(other_raw)
    assert_response :forbidden
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "x" },
         headers: bearer_headers(other_raw), as: :json
    assert_response :forbidden
  end
end
