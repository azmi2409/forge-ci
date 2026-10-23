# frozen_string_literal: true

require "test_helper"

# REQUEUE_ON_SHUTDOWN: a Spot runner told to shut down mid-job stops the
# running step and hands the job back to the queue. Off, nothing changes.
class RequeueOnShutdownTest < Minitest::Test
  # The real step loop and kill path; each `run` step is a local shell
  # command instead of `docker exec`, and docker setup/cleanup is a no-op.
  class ShellExecutor < ForgeCIRunner::Executor
    def stream_exec(argv, **kwargs)
      super(["sh", "-c", argv.last], **kwargs, no_output_timeout: 0)
    end

    private

    def run_docker(*_args)
      ["", 0]
    end
  end

  def shell_executor(requeue:)
    payload = test_payload("executor" => { "type" => "docker", "image" => "img" },
                           "steps" => [{ "type" => "run", "name" => "slow", "command" => "sleep 2" },
                                       { "type" => "run", "name" => "next", "command" => "true" }])
    ShellExecutor.new(test_config(requeue_on_shutdown: requeue), NullClient.new, payload)
  end

  def shutdown_after(seconds)
    flag = false
    Thread.new { sleep seconds; flag = true }
    -> { flag }
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # --- executor --------------------------------------------------------------

  def test_on_a_shutdown_stops_the_running_step_and_asks_for_a_requeue
    ex = shell_executor(requeue: true)
    ex.instance_variable_get(:@payload)["steps"][0]["command"] = "sleep 30"
    t0 = monotonic
    status, results = ex.execute(shutdown_after(0.5))
    assert_equal "requeue", status
    assert_operator monotonic - t0, :<, 10, "the step was stopped, not waited for"
    assert_equal [130, 0], results.map { |r| r["exit_code"] }, "slow was stopped, next skipped"
  end

  def test_on_a_shutdown_during_the_last_step_still_requeues
    ex = shell_executor(requeue: true)
    ex.instance_variable_get(:@payload)["steps"].pop
    ex.instance_variable_get(:@payload)["steps"][0]["command"] = "sleep 30"
    status, = ex.execute(shutdown_after(0.5))
    assert_equal "requeue", status
  end

  def test_on_a_cancel_wins_over_the_requeue
    ex = shell_executor(requeue: true)
    status, = ex.execute(-> { true }, cancel_check: -> { true })
    assert_equal "canceled", status
  end

  def test_on_without_a_shutdown_the_job_runs_normally
    status, = shell_executor(requeue: true).execute
    assert_equal "success", status
  end

  def test_off_the_running_step_finishes_and_the_job_is_canceled
    ex = shell_executor(requeue: false)
    status, results = ex.execute(shutdown_after(0.5))
    assert_equal "canceled", status
    assert_equal 0, results.first["exit_code"], "the in-flight step ran to the end"
    assert_equal %w[slow next], results.map { |r| r["name"] }
  end

  def test_config_reads_requeue_on_shutdown
    on = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t", "REQUEUE_ON_SHUTDOWN" => "1")
    off = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t")
    assert on.requeue_on_shutdown
    refute off.requeue_on_shutdown
  end

  # --- runner loop -------------------------------------------------------------

  class FakeClient
    attr_reader :calls

    def initialize(release_error: nil)
      @release_error = release_error
      @calls = []
    end

    def start_job(id) = @calls << [:start, id]
    def heartbeat(_id) = {}

    def complete_job(id, status, _results)
      @calls << [:complete, id, status]
    end

    def release_job(id, reason)
      @calls << [:release, id, reason]
      raise @release_error if @release_error
    end
  end

  class FakeExecutor
    def initialize(status)
      @status = status
    end

    def execute(_shutdown_check, cancel_check:)
      [@status, [{ "name" => "slow", "exit_code" => 130 }]]
    end
  end

  class TestRunner < ForgeCIRunner::Runner
    attr_writer :executor_status

    private

    def log(_message); end
    def build_executor(_payload) = FakeExecutor.new(@executor_status)
  end

  def run_one(status, client)
    r = TestRunner.new(test_config(heartbeat_interval: 0.01, requeue_on_shutdown: true))
    r.instance_variable_set(:@client, client)
    r.instance_variable_set(:@shutdown_signal, "SIGTERM")
    r.executor_status = status
    r.send(:run_job, { "id" => 5, "name" => "test" })
  end

  def test_a_requeue_releases_the_job_instead_of_completing_it
    client = FakeClient.new
    run_one("requeue", client)
    assert_equal [[:start, 5], [:release, 5, "runner shutting down (SIGTERM)"]], client.calls
  end

  def test_a_refused_release_reports_the_job_canceled
    client = FakeClient.new(release_error: ForgeCIRunner::Client::HTTPError.new("409", "{}"))
    run_one("requeue", client)
    assert_equal [:complete, 5, "canceled"], client.calls.last
  end

  def test_an_unreachable_control_plane_on_release_also_falls_back_to_canceled
    client = FakeClient.new(release_error: Errno::ECONNREFUSED)
    run_one("requeue", client)
    assert_equal [:complete, 5, "canceled"], client.calls.last
  end

  def test_other_statuses_complete_as_before
    client = FakeClient.new
    run_one("canceled", client)
    assert_equal [[:start, 5], [:complete, 5, "canceled"]], client.calls
  end
end
