# frozen_string_literal: true

require "test_helper"

# Exercises the real stream_exec (no docker involved: it just runs the argv).
class TimeoutCancelTest < Minitest::Test
  class Streamer
    attr_reader :out

    def initialize
      @out = +""
    end

    def write(text)
      @out << text
    end

    def flush; end
  end

  def build(config_overrides = {})
    ex = ForgeCIRunner::Executor.new(test_config(config_overrides), NullClient.new, test_payload)
    streamer = Streamer.new
    ex.instance_variable_set(:@streamer, streamer)
    ex.instance_variable_set(:@cancel_check, -> { false })
    [ex, streamer]
  end

  def test_normal_command_streams_output_and_exit_code
    ex, streamer = build
    code = ex.send(:stream_exec, ["sh", "-c", "echo hello; exit 3"])
    assert_equal 3, code
    assert_includes streamer.out, "hello"
  end

  def test_silent_step_is_killed_after_no_output_timeout
    ex, streamer = build
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code = ex.send(:stream_exec, ["sh", "-c", "sleep 30"], no_output_timeout: 1)
    assert_equal 124, code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 10
    assert_includes streamer.out, "no output for 1s"
  end

  def test_output_resets_the_no_output_timer
    ex, _streamer = build
    code = ex.send(:stream_exec, ["sh", "-c", "for i in 1 2 3; do echo tick; sleep 0.8; done"],
                   no_output_timeout: 2)
    assert_equal 0, code
  end

  def test_job_deadline_kills_the_step
    ex, streamer = build(job_timeout: 1.0)
    ex.instance_variable_set(:@job_deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)
    code = ex.send(:stream_exec, ["sh", "-c", "echo hi; while true; do echo x; sleep 0.2; done"],
                   no_output_timeout: 0)
    assert_equal 124, code
    assert_includes streamer.out, "JOB_TIMEOUT"
  end

  def test_cancel_stops_the_running_step
    ex, streamer = build
    flag = false
    ex.instance_variable_set(:@cancel_check, -> { flag })
    Thread.new { sleep 1; flag = true }
    code = ex.send(:stream_exec, ["sh", "-c", "sleep 30"], no_output_timeout: 0)
    assert_equal 130, code
    assert_includes streamer.out, "canceled"
  end

  def test_parse_duration
    ex, = build
    assert_equal 30.0, ex.send(:parse_duration, "30s")
    assert_equal 600.0, ex.send(:parse_duration, "10m")
    assert_equal 3600.0, ex.send(:parse_duration, "1h")
    assert_equal 45.0, ex.send(:parse_duration, "45")
    assert_nil ex.send(:parse_duration, "soon")
    assert_nil ex.send(:parse_duration, nil)
  end

  def test_step_environment_is_passed_to_docker_exec
    ex, = build
    argv = ex.exec_argv({ "command" => "env", "environment" => { "FOO" => "bar" } })
    assert_includes argv, "FOO=bar"
  end

  def test_config_reads_timeout_settings
    cfg = ForgeCIRunner::Config.from_env({ "CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t",
                                           "STEP_NO_OUTPUT_TIMEOUT" => "30", "JOB_TIMEOUT" => "0" })
    assert_equal 30.0, cfg.step_no_output_timeout
    assert_equal 0.0, cfg.job_timeout
  end
end
