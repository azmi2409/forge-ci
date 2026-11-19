# frozen_string_literal: true

require "test_helper"
require "rbconfig"
require "tmpdir"

class DockerTimeoutTest < Minitest::Test
  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def with_docker(hang_on, watchdog_bound: 1, ignore_term: false, spawn_child: false)
    Dir.mktmpdir("forge-ci-docker-timeout") do |dir|
      calls = File.join(dir, "calls")
      docker = File.join(dir, "docker")
      File.write(docker, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        trap("TERM", "IGNORE") if #{ignore_term.inspect}
        File.open(#{calls.inspect}, "a") { |f| f.puts(JSON.generate([Process.pid, ARGV, Process.clock_gettime(Process::CLOCK_MONOTONIC)])) }
        if ARGV.include?(#{hang_on.inspect})
          if #{spawn_child.inspect}
            child = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 300")
            File.open(#{calls.inspect}, "a") { |f| f.puts(JSON.generate([child, ARGV, Process.clock_gettime(Process::CLOCK_MONOTONIC)])) }
            trap("TERM") { Process.wait(child); exit }
          end
          sleep 300
        end
      RUBY
      File.chmod(0o755, docker)
      expired = []
      watchdog = Thread.new do
        loop do
          sleep 0.02
          next unless File.exist?(calls)

          File.readlines(calls).each do |line|
            pid, args, started = JSON.parse(line)
            next unless args.include?(hang_on) && monotonic - started > watchdog_bound

            begin
              Process.kill("KILL", pid)
              expired << pid
            rescue Errno::ESRCH
              nil
            end
          end
        end
      end
      begin
        yield docker, calls
        assert_empty expired, "Docker operation exceeded the test watchdog's bound"
        File.readlines(calls).each do |line|
          pid = JSON.parse(line).first
          assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        end
      ensure
        watchdog.kill
        watchdog.join
      end
    end
  end

  def test_pull_obeys_job_timeout_and_still_removes_containers
    with_docker("pull") do |docker, calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker, job_timeout: 0.2), NullClient.new,
                                      test_payload("executor" => { "image" => "fake" }))
      status, results = ex.execute
      assert_equal "failed", status
      assert_empty results
      args = File.readlines(calls).map { |line| JSON.parse(line)[1] }
      assert args.any? { |a| a[0, 2] == ["rm", "-f"] }, "cleanup must run after job deadline"
      assert args.any? { |a| a[0, 2] == ["network", "rm"] }
      refute args.any? { |a| a.first == "run" }
    end
  end

  def test_control_operations_and_silent_queries_obey_job_deadline
    [["network", "create", "fake"], ["run", "fake"], ["exec", "fake"], ["cp", "a", "b"], ["buildx", "inspect"]].each do |args|
      with_docker(args.first) do |docker, _calls|
        ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
        ex.instance_variable_set(:@job_deadline, monotonic + 0.2)
        _out, code = ex.send(:run_docker, docker, *args)
        assert_equal 124, code
      end
    end
    with_docker("sha256sum") do |docker, _calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      ex.instance_variable_set(:@job_deadline, monotonic + 0.2)
      assert_nil ex.send(:container_sha256, "file")
    end
  end

  def test_service_is_registered_for_cleanup_before_a_timed_out_start
    with_docker("run") do |docker, calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker, job_timeout: 0.5), NullClient.new, test_payload)
      status, = ex.execute
      assert_equal "failed", status
      args = File.readlines(calls).map { |line| JSON.parse(line)[1] }
      run = args.find { |a| a.first == "run" }
      refute_nil run, "service startup must be reached"
      service_name = run[run.index("--name") + 1]
      assert args.include?(["rm", "-f", service_name]), "remove service even when its start response times out"
    end
  end

  def test_step_exec_uses_no_output_timeout_and_reaps_child
    with_docker("exec") do |docker, _calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      assert_equal 124, ex.send(:stream_exec, [docker, "exec"], no_output_timeout: 0.2)
    end
  end

  def test_step_timeout_removes_container_and_skips_even_always_steps
    with_docker("hang-step") do |docker, calls|
      payload = test_payload("executor" => { "image" => "fake" }, "steps" => [
                               { "type" => "run", "command" => "hang-step", "no_output_timeout" => "0.2s" },
                               { "type" => "run", "command" => "must-not-run", "when" => "always" }
                             ])
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, payload)
      status, results = ex.execute
      assert_equal "failed", status
      assert_equal [124, 0], results.map { |r| r["exit_code"] }
      args = File.readlines(calls).map { |line| JSON.parse(line)[1] }
      refute args.any? { |a| a.include?("must-not-run") }
      assert_equal 2, args.count { |a| a[0, 2] == ["rm", "-f"] }
    end
  end

  def test_startup_info_has_its_own_ten_second_timeout
    with_docker("info", watchdog_bound: 13) do |docker, _calls|
      started = monotonic
      refute ForgeCIRunner::Executor.docker_available?(docker)
      assert_in_delta 10, monotonic - started, 1
    end
  end

  def test_term_ignoring_process_is_killed_after_grace_period
    with_docker("pull", watchdog_bound: 7, ignore_term: true) do |docker, _calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      ex.instance_variable_set(:@job_deadline, monotonic + 0.2)
      _out, code = ex.send(:run_docker, docker, "pull", "fake")
      assert_equal 124, code
    end
  end

  def test_timeout_kills_the_entire_process_group
    with_docker("pull", spawn_child: true) do |docker, calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      ex.instance_variable_set(:@job_deadline, monotonic + 0.2)
      _out, code = ex.send(:run_docker, docker, "pull", "fake")
      assert_equal 124, code
      assert_equal 2, File.readlines(calls).size
    end
  end

  def test_success_empty_output_and_nonzero_exit_are_preserved
    with_docker("never") do |docker, _calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      assert_equal ["", 0], ex.send(:run_docker, docker, "info")
      assert_equal ["message雪\n", 3], ex.send(:run_docker, RbConfig.ruby, "-e", "puts 'message雪'; exit 3")
    end
  end

  def test_cancel_and_requeue_interrupt_control_operations_but_not_cleanup
    [:canceled, :requeue].each do |reason|
      with_docker("pull") do |docker, calls|
        ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
        started = monotonic
        ex.instance_variable_set(reason == :canceled ? :@cancel_check : :@requeue_check, -> { monotonic - started > 0.2 })
        _out, code = ex.send(:run_docker, docker, "pull", "fake")
        assert_equal 130, code
        assert ex.instance_variable_get(:@stopped_for_requeue) if reason == :requeue
        ex.send(:cleanup_containers)
        assert File.readlines(calls).any? { |line| JSON.parse(line)[1][0, 2] == ["rm", "-f"] }
      end
    end
  end

  def test_cleanup_has_a_fresh_shared_budget_after_job_deadline
    with_docker("rm") do |docker, calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker), NullClient.new, test_payload)
      ex.instance_variable_set(:@job_deadline, monotonic - 1)
      ex.define_singleton_method(:cleanup_budget) { 0.2 }
      ex.send(:cleanup_containers)
      args = File.readlines(calls).map { |line| JSON.parse(line)[1] }
      assert_equal 1, args.size, "cleanup commands share one budget"
      assert_equal ["rm", "-f"], args.first[0, 2]
    end
  end

  def test_cleanup_time_does_not_count_against_successful_job
    with_docker("never") do |docker, _calls|
      ex = ForgeCIRunner::Executor.new(test_config(docker_bin: docker, job_timeout: 2), NullClient.new,
                                      test_payload("executor" => { "image" => "fake" }, "steps" => []))
      cleanup = ex.method(:cleanup_containers)
      ex.define_singleton_method(:cleanup_containers) do
        @job_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
        cleanup.call
      end
      status, = ex.execute
      assert_equal "success", status
    end
  end
end
