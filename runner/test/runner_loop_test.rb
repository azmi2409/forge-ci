# frozen_string_literal: true

require "test_helper"

# The daemon loop with a scripted client and a fake clock.
class RunnerLoopTest < Minitest::Test
  # Claim replies in order (nil = nothing claimable); then stops the runner.
  class ScriptedClient
    attr_reader :claims

    def initialize(replies, on_empty)
      @replies = replies
      @on_empty = on_empty
      @claims = 0
    end

    def claim_job(_resource_class)
      @claims += 1
      return @on_empty.call if @replies.empty?

      @replies.shift
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

  def test_no_idle_shutdown_by_default
    polls = 0
    r = nil
    r = runner([], on_empty: -> { (polls += 1) > 50 ? (r.stop!; nil) : nil })
    r.run
    assert_operator r.clock, :>, 600, "it kept polling well past any idle limit"
    assert_empty r.shell
  end
end
