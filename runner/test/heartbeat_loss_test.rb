# frozen_string_literal: true

require "test_helper"
require "timeout"

class HeartbeatLossTest < Minitest::Test
  class Client
    attr_reader :completions, :heartbeats

    def initialize(reply: {}, error: nil, completion_error: nil)
      @reply, @error, @completion_error = reply, error, completion_error
      @completions = []
      @heartbeats = 0
    end

    def start_job(_id); end

    def heartbeat(_id)
      @heartbeats += 1
      raise @error if @error

      @reply
    end

    def complete_job(_id, status, _results)
      @completions << status
      raise @completion_error if @completion_error
    end
  end

  class Executor
    def execute(_shutdown_check, cancel_check:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.25
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        return ["canceled", []] if cancel_check.call

        sleep 0.005
      end
      ["success", []]
    end
  end

  class Runner < ForgeCIRunner::Runner
    private

    def log(_message); end
    def build_executor(_payload) = Executor.new
  end

  def run_one(client)
    runner = Runner.new(test_config(heartbeat_interval: 0.01))
    runner.instance_variable_set(:@client, client)
    runner.send(:run_job, { "id" => 5, "name" => "heartbeat-test" })
    assert_operator client.heartbeats, :>, 0
  end

  def test_stopped_sleeping_heartbeat_cannot_cancel_the_next_job
    runner = Runner.new(test_config(heartbeat_interval: 15))
    sleeping = Queue.new
    runner.define_singleton_method(:sleep) do |_interval|
      gate = Queue.new
      sleeping << gate
      gate.pop
    end
    runner.instance_variable_set(:@client, Client.new(reply: { "status" => "success" }))
    old = runner.send(:start_heartbeat, 1)
    old_gate = Timeout.timeout(2) { sleeping.pop }

    runner.send(:stop_heartbeat, old)
    current = runner.send(:start_heartbeat, 2)
    Timeout.timeout(2) { sleeping.pop }
    old_gate << true
    old.join(2)

    refute runner.instance_variable_get(:@job_canceled), "old heartbeat canceled the next job"
    refute old.alive?, "stopped heartbeat thread is still alive"
  ensure
    [old, current].compact.each { |thread| thread.kill.join }
  end

  def test_stopped_in_flight_heartbeat_cannot_cancel_the_next_job
    runner = Runner.new(test_config(heartbeat_interval: 0.01))
    entered = Queue.new
    response = Queue.new
    client = Client.new
    client.define_singleton_method(:heartbeat) do |id|
      if id == 1
        entered << true
        response.pop
      else
        { "status" => "running" }
      end
    end
    runner.instance_variable_set(:@client, client)
    old = runner.send(:start_heartbeat, 1)
    Timeout.timeout(2) { entered.pop }

    runner.send(:stop_heartbeat, old)
    current = runner.send(:start_heartbeat, 2)
    response << { "status" => "failed" }
    old.join(2)

    refute runner.instance_variable_get(:@job_canceled), "late heartbeat response canceled the next job"
    refute old.alive?, "stopped heartbeat thread is still alive"
  ensure
    [old, current].compact.each { |thread| thread.kill.join }
  end

  %w[failed success canceled pending queued].each do |status|
    define_method("test_heartbeat_#{status}_stops_execution_and_tolerates_completion_rejection") do
      client = Client.new(reply: { "status" => status },
                          completion_error: ForgeCIRunner::Client::HTTPError.new("422", "{}"))
      run_one(client)
      assert_equal ["canceled"], client.completions
    end
  end

  %w[401 403 404].each do |code|
    define_method("test_heartbeat_#{code}_stops_execution_and_tolerates_completion_rejection") do
      error = ForgeCIRunner::Client::HTTPError.new(code, "{}")
      client = Client.new(error: error, completion_error: error)
      run_one(client)
      assert_equal ["canceled"], client.completions
    end
  end

  [{ "status" => "claimed" }, { "status" => "running" }, {}].each_with_index do |reply, index|
    define_method("test_active_or_empty_heartbeat_#{index}_keeps_execution_running") do
      client = Client.new(reply: reply)
      run_one(client)
      assert_equal ["success"], client.completions
    end
  end

  [ForgeCIRunner::Client::HTTPError.new("503", "{}"), IOError.new("connection reset")].each_with_index do |error, index|
    define_method("test_transient_heartbeat_error_#{index}_keeps_execution_running") do
      client = Client.new(error: error)
      run_one(client)
      assert_equal ["success"], client.completions
    end
  end
end
