# frozen_string_literal: true

require "test_helper"

class Api::V1::JobsControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @token_record, @raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir }, headers: admin_headers, as: :json
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

  # --- blob-backed logs (component 6) -----------------------------------------

  test "chunk posts are kept as rows; the blob is written once the job finishes" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 1, chunk: "second\n" }, headers: auth, as: :json
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "first\n" }, headers: auth, as: :json

    job = JobRun.find(@job_id)
    assert_not job.log_blob.attached?, "no blob rewrite per chunk"
    assert_equal "first\nsecond\n", job.log_text

    post "/api/v1/runner/jobs/#{@job_id}/complete", params: { status: "success", step_results: [] }, headers: auth, as: :json
    assert_equal "first\nsecond\n", job.reload.log_blob.download
  end

  test "logs?after returns only newer chunks, then the whole log once complete" do
    3.times { |i| post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: i, chunk: "line #{i}\n" }, headers: auth, as: :json }
    get "/api/v1/jobs/#{@job_id}/logs", params: { after: 0 }, headers: auth
    assert_equal [1, 2], json_body["chunks"].map { |c| c["seq"] }
    assert_equal false, json_body["complete"]

    get "/api/v1/jobs/#{@job_id}/logs", params: { after: 2 }, headers: auth
    assert_equal [], json_body["chunks"]

    post "/api/v1/runner/jobs/#{@job_id}/complete", params: { status: "failed", step_results: [] }, headers: auth, as: :json
    get "/api/v1/jobs/#{@job_id}/logs", params: { after: 2 }, headers: auth
    assert_equal true, json_body["complete"]
    assert_equal "failed", json_body["status"]
    assert_equal "line 0\nline 1\nline 2\n", json_body["chunks"].map { |c| c["chunk"] }.join
  end

  test "new chunks and the job's end are announced on its JobLogChannel stream" do
    stream = JobLogChannel.stream_name(@job_id)
    assert_broadcast_on(stream, { "event" => "chunk", "seq" => 0 }) do
      post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "hi\n" }, headers: auth, as: :json
    end
    assert_broadcast_on(stream, { "event" => "done", "status" => "success" }) do
      post "/api/v1/runner/jobs/#{@job_id}/complete", params: { status: "success", step_results: [] }, headers: auth, as: :json
    end
  end

  test "terminal jobs purge rows and serve logs from the blob" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "hello\n" }, headers: auth, as: :json
    post "/api/v1/runner/jobs/#{@job_id}/complete", params: { status: "success", step_results: [] },
         headers: auth, as: :json
    assert_response :ok

    job = JobRun.find(@job_id)
    assert_equal 0, job.log_chunks.count
    assert job.log_blob.attached?

    get "/api/v1/jobs/#{@job_id}/logs", headers: auth
    assert_response :ok
    chunks = json_body["chunks"]
    assert_equal "hello\n", chunks.map { |c| c["chunk"] }.join
  end

  test "log stream emits chunks then a done event for a finished job" do
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "line one\n" }, headers: auth, as: :json
    post "/api/v1/runner/jobs/#{@job_id}/complete", params: { status: "success", step_results: [] },
         headers: auth, as: :json
    assert_response :ok

    get "/api/v1/jobs/#{@job_id}/logs/stream", headers: auth
    assert_response :ok
    assert_equal "text/event-stream", response.headers["Content-Type"]
    body = response.body
    assert_includes body, "line one\\n"
    assert_includes body, "event: done"
  end

  test "log stream accepts UI basic auth" do
    sign_in_as_admin
    get "/api/v1/jobs/#{@job_id}/logs/stream"
    assert_response :ok
    assert_equal "text/event-stream", response.headers["Content-Type"]
  end

  test "log stream rejects unauthenticated requests" do
    get "/api/v1/jobs/#{@job_id}/logs/stream"
    assert_response :unauthorized
  end

  test "log stream for a job that hasn't started ends at once with a waiting event" do
    pending_job = @pipeline.job_runs.find_by!(name: "test")
    assert pending_job.pending?
    sign_in_as_admin
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/api/v1/jobs/#{pending_job.id}/logs/stream"
    assert_response :ok
    assert_includes response.body, "event: waiting"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
  end

  test "log stream for a running job stops after the stream timeout instead of holding a thread" do
    old = ENV["FORGE_CI_STREAM_TIMEOUT_SECONDS"]
    ENV["FORGE_CI_STREAM_TIMEOUT_SECONDS"] = "1"
    post "/api/v1/jobs/#{@job_id}/log_chunks", params: { seq: 0, chunk: "still going\n" }, headers: auth, as: :json
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/api/v1/jobs/#{@job_id}/logs/stream", headers: auth
    assert_response :ok
    assert_includes response.body, "still going"
    assert_not_includes response.body, "event: done"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
  ensure
    old.nil? ? ENV.delete("FORGE_CI_STREAM_TIMEOUT_SECONDS") : ENV["FORGE_CI_STREAM_TIMEOUT_SECONDS"] = old
  end
end
