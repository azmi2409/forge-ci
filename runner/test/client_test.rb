# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  def setup
    @server = FakeControlPlane.new
    @client = ForgeCIRunner::Client.new(runner_config_for(@server))
  end

  def teardown
    @server.close
  end

  def test_claim_returns_payload_and_sends_auth
    payload = { "id" => 7, "name" => "build" }
    @server.stub("POST", "/api/v1/runner/jobs/claim", "200", payload)

    result = @client.claim_job("medium")

    assert_equal payload, result
    req = @server.last_request
    assert_equal "Bearer test-token", req[:headers]["authorization"]
    assert_equal({ "resource_class" => "medium" }, JSON.parse(req[:body]))
  end

  def test_claim_omits_resource_class_when_nil
    @server.stub("POST", "/api/v1/runner/jobs/claim", "200", { "id" => 1 })
    @client.claim_job(nil)
    assert_equal({}, JSON.parse(@server.last_request[:body]))
  end

  def test_claim_returns_nil_on_422
    @server.stub("POST", "/api/v1/runner/jobs/claim", "422",
                 { "error" => "nothing claimable" })
    assert_nil @client.claim_job("medium")
    assert_equal 0, @client.upcoming
  end

  def test_claim_remembers_upcoming_jobs
    @server.stub("POST", "/api/v1/runner/jobs/claim", "422",
                 { "error" => "nothing claimable", "upcoming" => 2 })
    assert_nil @client.claim_job("deploy")
    assert_equal 2, @client.upcoming
  end

  def test_claim_raises_on_401
    @server.stub("POST", "/api/v1/runner/jobs/claim", "401",
                 { "error" => "bad token" })
    err = assert_raises(ForgeCIRunner::Client::HTTPError) { @client.claim_job("medium") }
    assert_equal "401", err.code
  end

  def test_complete_posts_status_and_step_results
    @server.stub("POST", "/api/v1/runner/jobs/9/complete", "200",
                 { "id" => 9, "status" => "success" })
    steps = [{ "name" => "Bundle", "exit_code" => 0,
               "started_at" => "2026-10-15T10:00:00Z",
               "finished_at" => "2026-10-15T10:01:00Z" }]
    @client.complete_job(9, "success", steps)

    body = JSON.parse(@server.last_request[:body])
    assert_equal "success", body["status"]
    assert_equal steps, body["step_results"]
  end

  def test_log_chunk_posts_seq_and_chunk
    @server.stub("POST", "/api/v1/jobs/9/log_chunks", "200",
                 { "job_id" => 9, "seq" => 3 })
    @client.post_log_chunk(9, 3, "hello\n")
    body = JSON.parse(@server.last_request[:body])
    assert_equal({ "seq" => 3, "chunk" => "hello\n" }, body)
  end

  def test_start_and_heartbeat_paths
    @server.stub("POST", "/api/v1/runner/jobs/9/start", "200", { "id" => 9 })
    @server.stub("POST", "/api/v1/runner/jobs/9/heartbeat", "200",
                 { "id" => 9, "status" => "running" })
    @client.start_job(9)
    @client.heartbeat(9)
    paths = @server.requests.map { |r| r[:path] }
    assert_equal ["/api/v1/runner/jobs/9/start",
                  "/api/v1/runner/jobs/9/heartbeat"], paths
  end
end
