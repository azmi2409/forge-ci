# frozen_string_literal: true

module ForgeCIRunner
  # Main daemon loop: poll → claim → start → execute → complete.
  #
  # SIGTERM/SIGINT: stop claiming new jobs; the current job finishes its
  # in-flight step, remaining steps are skipped, and the job is reported
  # as "canceled". Exits cleanly. With REQUEUE_ON_SHUTDOWN (Spot runners)
  # the in-flight step is stopped too and the job is released back to the
  # queue for another runner; if the release is refused it is canceled.
  #
  # Idle polls back off from POLL_INTERVAL up to MAX_IDLE_INTERVAL. Once
  # IDLE_SHUTDOWN_AFTER elapses, bounded outlook-driven linger can keep this
  # class/pool warm for expected work; then the runner shuts down.
  class Runner
    def initialize(config)
      @config = config
      @client = Client.new(config)
      @backoff = Backoff.new(base: config.poll_interval,
                             max: config.max_idle_interval)
      @shutdown = false
      @idle_since = monotonic
      @linger_until = nil
    end

    def run
      trap_signals
      log("forge-ci-runner #{VERSION} starting " \
          "(#{@config.control_plane_url}, resource_class=#{@config.resource_class || "any"})")

      until @shutdown
        if @linger_until && monotonic >= @linger_until
          idle_shutdown
          break
        end

        claim_timeout = @linger_until && [@linger_until - monotonic, 0].max
        payload = poll_once(timeout: claim_timeout)
        break if @shutdown

        if payload.nil?
          if @client.no_work
            break if idle_wait_or_shutdown
          else
            # Outage or error: back off, but never count it as idle.
            pause(@backoff.tick)
          end

          next
        end

        @backoff.reset
        run_job(payload)
        @idle_since = monotonic
        @linger_until = nil
      end

      log("forge-ci-runner stopped")
    end

    private

    # The claimed job's payload, or nil when there is nothing to claim or the
    # control plane could not be reached (the caller backs off either way).
    def poll_once(timeout: nil)
      if timeout
        @client.claim_job(@config.resource_class, timeout: timeout)
      else
        @client.claim_job(@config.resource_class)
      end
    rescue Client::HTTPError => e
      # Bad token: fail fast and loud instead of backing off forever.
      raise if e.code == "401"

      log("control plane error (HTTP #{e.code}); backing off")
      nil
    rescue StandardError => e
      log("poll error: #{e.class}: #{e.message}; backing off")
      nil
    end

    def idle_too_long?
      limit = @config.idle_shutdown_after.to_f
      limit.positive? && monotonic - @idle_since >= limit
    end

    # Returns true once idle shutdown should end the process. Outlook errors
    # are fail-closed: at base idle, an unavailable/older server means use the
    # old immediate-shutdown behavior rather than linger without evidence.
    def idle_wait_or_shutdown
      if @client.upcoming.to_i.positive?
        # Work is coming (e.g. a deploy waiting on checks): not idle.
        @idle_since = monotonic
        @linger_until = nil
        pause(@backoff.tick)
        return false
      end

      limit = @config.idle_shutdown_after.to_f
      unless limit.positive?
        pause(@backoff.tick)
        return false
      end

      if @linger_until
        remaining = @linger_until - monotonic
        return shutdown_idle unless remaining.positive?
        return shutdown_idle unless outlook_has_work?(timeout: remaining)
        return shutdown_idle if monotonic >= @linger_until

        pause_lingering
        return false
      end

      unless idle_too_long?
        pause(@backoff.tick)
        return false
      end

      linger_max = @config.idle_linger_max.to_f
      return shutdown_idle unless linger_max.positive?

      # Measure the cap from the base-idle deadline, not the later poll that
      # happened to notice that deadline. Bound the request by the same cap.
      @linger_until = @idle_since + limit + linger_max
      remaining = @linger_until - monotonic
      return shutdown_idle unless remaining.positive?
      return shutdown_idle unless outlook_has_work?(timeout: remaining)
      return shutdown_idle if monotonic >= @linger_until

      pause_lingering
      false
    end

    def outlook_has_work?(timeout:)
      outlook = @client.outlook(@config.resource_class, timeout: timeout)
      %w[queued running pending].sum { |key| outlook[key].to_i }.positive?
    rescue StandardError => e
      log("runner outlook unavailable (#{e.class}: #{e.message}); shutting down at base idle")
      false
    end

    def pause_lingering
      remaining = @linger_until - monotonic
      return unless remaining.positive?

      interval = @config.idle_outlook_interval.to_f
      pause([interval.positive? ? interval : 15.0, remaining].min)
    end

    def shutdown_idle
      idle_shutdown
      true
    end

    def idle_shutdown
      log("idle for #{@config.idle_shutdown_after.to_i}s; shutting down")
      command = @config.idle_shutdown_command.to_s
      return if command.empty?

      log("running IDLE_SHUTDOWN_COMMAND")
      ok = system(command)
      log("IDLE_SHUTDOWN_COMMAND failed (exit #{$?&.exitstatus})") unless ok
    end

    # Seams for tests.
    def pause(seconds)
      sleep seconds
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def build_executor(payload)
      Executor.new(@config, @client, payload)
    end

    def run_job(payload)
      job_id = payload["id"]
      log("claimed job ##{job_id} (#{payload["name"]})")

      executor = build_executor(payload)
      @client.start_job(job_id)

      heartbeat = start_heartbeat(job_id)
      begin
        status, step_results = executor.execute(-> { @shutdown }, cancel_check: -> { @job_canceled })
        if status == "requeue"
          release_job(job_id, step_results)
        else
          @client.complete_job(job_id, status, step_results)
          log("job ##{job_id} #{status}")
        end
      rescue Client::HTTPError => e
        # e.g. 403 because the job was reclaimed after our heartbeats died.
        log("could not report job ##{job_id}: HTTP #{e.code}")
      rescue StandardError => e
        log("job ##{job_id} runner error: #{e.class}: #{e.message}")
        begin
          @client.complete_job(job_id, "failed", [])
        rescue StandardError => e2
          log("could not report failure for job ##{job_id}: #{e2.message}")
        end
      ensure
        stop_heartbeat(heartbeat)
      end
    end

    # Back to the queue, so another runner runs it from the start. When the
    # control plane refuses (release limit, older server) or can't be
    # reached, report it canceled as a runner without the flag would.
    def release_job(job_id, step_results)
      @client.release_job(job_id, "runner shutting down (#{@shutdown_signal || "signal"})")
      log("job ##{job_id} released back to the queue")
    rescue StandardError => e
      log("could not release job ##{job_id} (#{e.message}); reporting it canceled")
      @client.complete_job(job_id, "canceled", step_results)
      log("job ##{job_id} canceled")
    end

    def start_heartbeat(job_id)
      @heartbeat_stop = false
      @job_canceled = false
      Thread.new do
        until @heartbeat_stop
          sleep @config.heartbeat_interval
          break if @heartbeat_stop

          begin
            reply = @client.heartbeat(job_id)
            # The control plane cancels a job (pipeline canceled) by flipping
            # its status; the heartbeat reply tells us to stop.
            if reply.is_a?(Hash) && reply["status"] == "canceled" && !@job_canceled
              log("job ##{job_id} was canceled by the control plane; stopping")
              @job_canceled = true
            end
          rescue StandardError => e
            log("heartbeat failed for job ##{job_id}: #{e.class}: #{e.message}")
          end
        end
      end
    end

    def stop_heartbeat(thread)
      @heartbeat_stop = true
      thread&.join(5)
    end

    def trap_signals
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          plan = @config.requeue_on_shutdown ? "releasing current job" : "finishing current job"
          log("received #{sig}; #{plan}, no new claims")
          @shutdown_signal = "SIG#{sig}"
          @shutdown = true
        end
      end
    end

    def log(message)
      $stderr.puts "[forge-ci-runner] #{message}"
    end
  end
end
