# frozen_string_literal: true

require "test_helper"
require "tempfile"

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

  def test_presence_identity_is_stable_across_idle_claims_and_heartbeats
    @server.stub("POST", "/api/v1/runner/jobs/claim", "422", { "upcoming" => 0 })
    @server.stub("POST", "/api/v1/runner/jobs/9/heartbeat", "200", { "status" => "running" })
    assert_nil @client.claim_job(nil)
    first = @server.last_request[:headers]
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
                 first["x-forge-runner-id"])
    hostname = first["x-forge-runner-hostname"]
    assert_match(/\A[\x20-\x7e]{1,255}\z/, hostname)
    assert_equal hostname.strip, hostname
    assert_equal "ruby", first["x-forge-runner-implementation"]

    @client.heartbeat(9)
    assert_equal first["x-forge-runner-id"], @server.last_request[:headers]["x-forge-runner-id"]
    other = ForgeCIRunner::Client.new(runner_config_for(@server))
    assert_nil other.claim_job(nil)
    refute_equal first["x-forge-runner-id"], @server.last_request[:headers]["x-forge-runner-id"]
  end

  def test_download_redirects_do_not_send_auth_or_presence
    @server.stub_redirect("GET", "/redirect", "http://127.0.0.1:#{@server.port}/download")
    @server.stub_raw("GET", "/download", "200", "application/octet-stream", "bytes")
    Tempfile.create("runner-download") do |file|
      @client.download("http://127.0.0.1:#{@server.port}/redirect", file.path)
      assert_equal "bytes", File.binread(file.path)
    end
    assert_equal ["/redirect", "/download"], @server.requests.map { |request| request[:path] }
    @server.requests.each do |request|
      %w[authorization x-forge-runner-id x-forge-runner-hostname x-forge-runner-implementation].each do |name|
        assert_nil request[:headers][name]
      end
    end
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

  def test_outlook_gets_class_scoped_counts_with_runner_auth
    @server.stub("GET", "/api/v1/runner/outlook?resource_class=large", "200",
                 { "queued" => 2, "running" => 1, "pending" => 3 })
    assert_equal({ "queued" => 2, "running" => 1, "pending" => 3 }, @client.outlook("large"))
    request = @server.last_request
    assert_equal "GET", request[:method]
    assert_equal "Bearer test-token", request[:headers]["authorization"]
    assert_equal "/api/v1/runner/outlook?resource_class=large", request[:path]
  end

  def test_outlook_404_is_an_error_for_fail_closed_idle_handling
    @server.stub("GET", "/api/v1/runner/outlook", "404", { "error" => "not found" })
    error = assert_raises(ForgeCIRunner::Client::HTTPError) { @client.outlook(nil) }
    assert_equal "404", error.code
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

  def test_release_posts_the_reason
    @server.stub("POST", "/api/v1/runner/jobs/9/release", "200", { "id" => 9, "status" => "queued" })
    @client.release_job(9, "runner shutting down (SIGTERM)")
    req = @server.last_request
    assert_equal "/api/v1/runner/jobs/9/release", req[:path]
    assert_equal({ "reason" => "runner shutting down (SIGTERM)" }, JSON.parse(req[:body]))
  end

  def test_release_raises_on_409
    @server.stub("POST", "/api/v1/runner/jobs/9/release", "409", { "error" => "released too often" })
    err = assert_raises(ForgeCIRunner::Client::HTTPError) { @client.release_job(9, "x") }
    assert_equal "409", err.code
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
