# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"

class DockerProcessTest < Minitest::Test
  def test_deadline_remains_active_after_client_exit_with_descendant_holding_stdout
    descendant = nil
    watchdog = Thread.new do
      sleep 1
      Process.kill("KILL", descendant) if descendant
    rescue Errno::ESRCH
      nil
    end
    started = ForgeCIRunner::DockerProcess.monotonic
    script = "pid = Process.spawn(#{RbConfig.ruby.inspect}, '-e', 'sleep 300'); puts pid"
    _output, status, reason = ForgeCIRunner::DockerProcess.capture(
      [RbConfig.ruby, "-e", script], deadline: started + 0.2
    ) { |chunk| descendant = chunk.to_i }
    assert status.success?, "the direct client must exit successfully before the deadline"
    assert_equal :job_timeout, reason
    assert_operator ForgeCIRunner::DockerProcess.monotonic - started, :<, 0.8
  ensure
    watchdog&.kill&.join
    begin
      Process.kill("KILL", descendant) if descendant
    rescue Errno::ESRCH
      nil
    end
  end

  def test_successful_exit_drains_all_output_despite_a_slow_callback
    Dir.mktmpdir("forge-ci-slow-output") do |dir|
      gate = File.join(dir, "reading")
      delivered = +""
      first = true
      script = <<~RUBY
        STDOUT.sync = true
        puts "first"
        sleep 0.01 until File.exist?(ARGV.first)
        print "tail\\n" * 40
      RUBY
      output, status, reason = ForgeCIRunner::DockerProcess.capture([RbConfig.ruby, "-e", script, gate]) do |chunk|
        if first
          first = false
          File.write(gate, "ready")
          sleep 6
        end
        delivered << chunk
      end
      assert status.success?
      assert_nil reason
      assert_equal "first\n" + "tail\n" * 40, output
      assert_equal output, delivered
    end
  end

  def test_client_exit_does_not_disable_cancellation_or_silent_drain_bound
    [:canceled, :drain_timeout].each do |expected_reason|
      descendant = nil
      watchdog = Thread.new do
        sleep 7
        Process.kill("KILL", descendant) if descendant
      rescue Errno::ESRCH
        nil
      end
      started = ForgeCIRunner::DockerProcess.monotonic
      stop_check = -> { :canceled if expected_reason == :canceled && ForgeCIRunner::DockerProcess.monotonic - started > 0.2 }
      script = "pid = Process.spawn(#{RbConfig.ruby.inspect}, '-e', 'sleep 300'); puts pid"
      _out, status, reason = ForgeCIRunner::DockerProcess.capture([RbConfig.ruby, "-e", script], stop_check: stop_check) do |chunk|
        descendant = chunk.to_i
      end
      assert status.success?
      assert_equal expected_reason, reason
      assert_operator ForgeCIRunner::DockerProcess.monotonic - started, :<, expected_reason == :canceled ? 1 : 6.5
    ensure
      watchdog&.kill&.join
      begin
        Process.kill("KILL", descendant) if descendant
      rescue Errno::ESRCH
        nil
      end
    end
  end

  def test_active_output_after_client_exit_resets_the_idle_drain_bound
    script = <<~RUBY
      fork do
        STDOUT.sync = true
        7.times { puts "tick"; sleep 1 }
      end
    RUBY
    delivered = +""
    output, status, reason = ForgeCIRunner::DockerProcess.capture([RbConfig.ruby, "-e", script]) { |chunk| delivered << chunk }
    assert status.success?
    assert_nil reason
    assert_equal "tick\n" * 7, output
    assert_equal output, delivered
  end

  def test_deadline_counts_time_in_callback_even_after_client_exits
    gate = Queue.new
    entered = Queue.new
    watchdog = Thread.new { sleep 7; gate << true }
    started = ForgeCIRunner::DockerProcess.monotonic
    _out, status, reason = ForgeCIRunner::DockerProcess.capture(
      [RbConfig.ruby, "-e", "puts 'done'"], deadline: started + 0.2
    ) do |_chunk|
      entered << Thread.current
      gate.pop
    end
    assert status.success?
    assert_equal :job_timeout, reason
    assert_operator ForgeCIRunner::DockerProcess.monotonic - started, :<, 6.5
    refute entered.pop.alive?
  ensure
    watchdog&.kill&.join
  end

  def test_permanently_blocked_callback_is_ended_within_a_bound
    resume = Queue.new
    entered = Queue.new
    watchdog = Thread.new { sleep 7; resume << true }
    started = ForgeCIRunner::DockerProcess.monotonic
    _out, _status, reason = ForgeCIRunner::DockerProcess.capture(
      [RbConfig.ruby, "-e", "STDOUT.sync = true; puts Process.pid; sleep 300"], deadline: started + 0.2
    ) do |chunk|
      entered << [chunk.to_i, Thread.current]
      resume.pop
    end
    pid, reader = entered.pop
    assert_equal :job_timeout, reason
    assert_operator ForgeCIRunner::DockerProcess.monotonic - started, :<, 6.5
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    refute reader.alive?, "blocked callback thread leaked"
  ensure
    watchdog&.kill&.join
  end

  def test_callback_error_is_propagated_after_child_cleanup
    [RuntimeError, IOError].each do |error_class|
      pid = nil
      error = assert_raises(error_class) do
        ForgeCIRunner::DockerProcess.capture(
          [RbConfig.ruby, "-e", "STDOUT.sync = true; puts Process.pid; sleep 300"]
        ) do |chunk|
          pid = chunk.to_i
          raise error_class, "upload failed"
        end
      end
      assert_equal "upload failed", error.message
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end

  def test_blocked_output_callback_does_not_suspend_deadline_or_cancellation
    [:job_timeout, :no_output, :canceled].each do |reason|
      entered = Queue.new
      resume = Queue.new
      child_stopped = false
      observer = Thread.new do
        pid = entered.pop
        sleep 0.4
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          child_stopped = true
        ensure
          resume << true
        end
      end
      started = ForgeCIRunner::DockerProcess.monotonic
      options = case reason
                when :job_timeout then { deadline: started + 0.2 }
                when :no_output then { no_output_timeout: 0.2 }
                when :canceled then { stop_check: -> { :canceled if ForgeCIRunner::DockerProcess.monotonic - started > 0.2 } }
                end
      _out, _status, actual_reason = ForgeCIRunner::DockerProcess.capture(
        [RbConfig.ruby, "-e", "STDOUT.sync = true; puts Process.pid; sleep 300"], **options
      ) do |chunk|
        entered << chunk.to_i
        resume.pop
      end
      observer.join
      assert_equal reason, actual_reason
      assert child_stopped, "#{reason}: child remained alive while output callback was blocked"
    ensure
      observer&.kill&.join
    end
  end
end
