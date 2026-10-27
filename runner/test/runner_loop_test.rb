# frozen_string_literal: true

require "test_helper"

# The daemon loop with a scripted client and a fake clock.
class RunnerLoopTest < Minitest::Test
  # Claim replies in order (nil = nothing claimable); then stops the runner.
  class ScriptedClient
    attr_reader :claims, :outlook_requests, :outlook_timeouts, :claim_timeouts, :no_work
    attr_accessor :outlook_replies, :default_outlook, :upcoming

    def initialize(replies, on_empty)
      @replies = replies
      @on_empty = on_empty
      @upcoming = 0
      @claims = 0
      @outlook_replies = []
      @default_outlook = { "queued" => 0, "running" => 0, "pending" => 0 }
      @outlook_requests = 0
      @outlook_timeouts = []
      @claim_timeouts = []
    end

    def claim_job(_resource_class, timeout: nil)
      @claim_timeouts << timeout
      @claims += 1
      @no_work = true
      return @on_empty.call if @replies.empty?

      reply = @replies.shift
      if reply == :outage
        @no_work = false
        return nil
      end
      reply
    end

    def outlook(_resource_class, timeout: nil)
      @outlook_requests += 1
      @outlook_timeouts << timeout
      reply = @outlook_replies.empty? ? @default_outlook : @outlook_replies.shift
      raise reply if reply.is_a?(StandardError)

      reply
    end
  end

  class TestRunner < ForgeCIRunner::Runner
    attr_reader :pauses, :jobs, :shell
    attr_accessor :clock

    def initialize(config, client)
      @clock = 0.0
      super(config)
      @client = client
      @pauses = []
      @jobs = []
      @shell = []
    end

    def stop!
      @shutdown = true
    end

    private

    def trap_signals; end
    def log(_message); end
    def monotonic = @clock

    def pause(seconds)
      @pauses << seconds
      @clock += seconds
    end

    def run_job(payload)
      @jobs << payload["id"]
      @clock += 30
    end

    def system(command)
      @shell << command
      true
    end
  end

  def runner(replies, on_empty: nil, **config)
    r = TestRunner.new(test_config({ poll_interval: 5.0, max_idle_interval: 60.0 }.merge(config)), nil)
    r.instance_variable_set(:@client, ScriptedClient.new(replies, on_empty || -> { r.stop!; nil }))
    r
  end

  def test_idle_polls_back_off_instead_of_spinning
    r = runner([nil, nil, nil])
    r.run
    assert_equal 3, r.pauses.size, "every empty poll must pause"
    assert r.pauses.all?(&:positive?)
    assert_operator r.pauses.last, :>=, r.pauses.first
  end

  def test_idle_shutdown_runs_the_command_once_and_exits
    r = runner([], on_empty: -> { nil }, idle_shutdown_after: 120.0, idle_shutdown_command: "terminate-me")
    r.run # returns: the runner stops itself once idle long enough
    assert_equal ["terminate-me"], r.shell
    assert_operator r.clock, :>=, 120.0
  end

  def test_a_job_resets_the_idle_clock
    jobs = [nil, nil, { "id" => 7 }]
    r = runner(jobs, on_empty: -> { nil }, idle_shutdown_after: 100.0)
    r.run
    assert_equal [7], r.jobs
    # Idle time is counted from the end of job 7, not from start-up.
    assert_operator r.clock, :>=, 5 + 10 + 30 + 100
    assert_empty r.shell, "no command configured, so nothing runs"
  end

  def test_upcoming_work_suppresses_idle_shutdown
    r = nil
    r = runner([], on_empty: -> { r.stop! if r.clock > 300; nil }, idle_shutdown_after: 60.0,
               idle_shutdown_command: "terminate-me")
    r.instance_variable_get(:@client).upcoming = 2
    r.run
    assert_empty r.shell, "work is coming, so the runner must not shut down"
    assert_operator r.clock, :>, 300
  end

  def test_claim_outage_does_not_count_as_idle
    r = nil
    r = runner(Array.new(40) { :outage }, on_empty: -> { r.stop!; nil }, idle_shutdown_after: 60.0,
               idle_shutdown_command: "terminate-me")
    r.run
    assert_empty r.shell, "an outage is not no-work, so it must not shut the runner down"
    assert_operator r.clock, :>, 60.0
  end

  def test_no_idle_shutdown_by_default
    polls = 0
    r = nil
    r = runner([], on_empty: -> { (polls += 1) > 50 ? (r.stop!; nil) : nil })
    r.run
    assert_operator r.clock, :>, 600, "it kept polling well past any idle limit"
    assert_empty r.shell
  end

  def test_outlook_work_keeps_the_runner_up_until_it_claims_a_job
    r = runner([nil, nil, nil, { "id" => 7 }], on_empty: -> { r.stop!; nil },
               idle_shutdown_after: 10.0, idle_linger_max: 30.0, idle_outlook_interval: 5.0)
    client = r.instance_variable_get(:@client)
    client.outlook_replies = [{ "queued" => 0, "running" => 0, "pending" => 1 }]
    r.run
    assert_equal [7], r.jobs
    assert_operator client.outlook_requests, :>=, 1
    assert_operator client.outlook_timeouts.first, :>, 0, "outlook is bounded by the remaining linger cap"
    assert client.claim_timeouts.any? { |timeout| timeout&.positive? },
           "claim is bounded by the remaining linger cap"
    assert_empty r.shell
    assert_includes r.pauses, 5.0, "lingering uses the configured outlook interval"
  end

  def test_zero_outlook_shuts_down_at_base_idle
    r = runner([nil, nil], idle_shutdown_after: 5.0, idle_linger_max: 30.0,
               idle_shutdown_command: "terminate-me")
    r.run
    assert_equal ["terminate-me"], r.shell
    assert_equal 1, r.instance_variable_get(:@client).outlook_requests
  end

  def test_linger_max_bounds_positive_outlook
    r = runner([nil, nil, nil, nil], idle_shutdown_after: 5.0, idle_linger_max: 10.0,
               idle_outlook_interval: 5.0, idle_shutdown_command: "terminate-me")
    client = r.instance_variable_get(:@client)
    client.default_outlook = { "queued" => 1, "running" => 0, "pending" => 0 }
    r.run
    assert_equal ["terminate-me"], r.shell
    assert_operator r.clock, :>=, 15.0
    assert_equal 2, client.outlook_requests, "the cap expires before another outlook request"
  end

  def test_outlook_404_or_network_error_falls_back_to_base_shutdown
    [ForgeCIRunner::Client::HTTPError.new("404", "older server"), IOError.new("offline")].each do |error|
      r = runner([nil, nil], idle_shutdown_after: 5.0, idle_linger_max: 30.0,
                 idle_shutdown_command: "terminate-me")
      r.instance_variable_get(:@client).outlook_replies = [error]
      r.run
      assert_equal ["terminate-me"], r.shell
      assert_equal 5.0, r.clock
    end
  end

  def test_zero_linger_max_preserves_immediate_shutdown_without_outlook
    r = runner([nil, nil], idle_shutdown_after: 5.0, idle_linger_max: 0,
               idle_shutdown_command: "terminate-me")
    r.run
    assert_equal ["terminate-me"], r.shell
    assert_equal 0, r.instance_variable_get(:@client).outlook_requests
  end
end
