# frozen_string_literal: true

require "test_helper"

class AttemptHeadersTest < Minitest::Test
  class Executor
    def initialize(client)
      @client = client
    end

    def execute(*, **)
      @client.post_log_chunk(7, 0, "output")
      sleep 0.04
      ["success", []]
    end
  end

  def run_attempt(mode)
    server = FakeControlPlane.new
    runner = ForgeCIRunner::Runner.new(test_config(control_plane_url: "http://127.0.0.1:#{server.port}", heartbeat_interval: 0.01))
    runner.define_singleton_method(:build_executor) { |_payload| Executor.new(@client) }
    runner.define_singleton_method(:trap_signals) {}
    payload = { "id" => 7, "name" => "build", "attempt_token" => "attempt-a" }
    server.stub("POST", "/api/v1/runner/jobs/claim") do
      runner.instance_variable_set(:@shutdown, true) if mode == :after_claim
      FakeControlPlane::Response.new("200", payload)
    end
    %w[start heartbeat].each { |action| server.stub("POST", "/api/v1/runner/jobs/7/#{action}", "200", { "status" => "running" }) }
    server.stub("POST", "/api/v1/jobs/7/log_chunks", "200", {})
    server.stub("POST", "/api/v1/runner/jobs/7/release", "409", {})
    completions = 0
    server.stub("POST", "/api/v1/runner/jobs/7/complete") do
      completions += 1
      FakeControlPlane::Response.new(mode == :normal && completions == 1 ? "503" : "200", {})
    end
    if mode == :after_claim
      runner.run
    else
      claim = runner.instance_variable_get(:@client).claim_job(nil)
      runner.instance_variable_set(:@shutdown, true) if mode == :unstarted
      runner.send(:run_job, claim)
    end
    requests = server.requests
    assert_nil requests.find { |r| r[:path].end_with?("/claim") }[:headers]["x-forge-attempt"]
    expected = mode == :normal ? %w[start heartbeat complete log_chunks] : %w[release complete]
    expected.each { |action| assert requests.any? { |r| r[:path].end_with?("/#{action}") }, "missing #{action}" }
    requests.reject { |r| r[:path].end_with?("/claim") }.each do |request|
      assert_equal "attempt-a", request[:headers]["x-forge-attempt"], request[:path]
    end
    assert_equal mode == :normal ? 2 : 1, completions
  ensure
    server&.close
  end

  def test_runner_sends_attempt_on_lifecycle_logs_and_completion_retries
    run_attempt(:normal)
  end

  def test_unstarted_release_and_cancel_fallback_keep_attempt
    run_attempt(:unstarted)
  end

  def test_claim_arriving_after_shutdown_keeps_attempt_on_release_and_fallback
    run_attempt(:after_claim)
  end
end
