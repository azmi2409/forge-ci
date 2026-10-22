# frozen_string_literal: true

module ForgeCIRunner
  # Main daemon loop: poll → claim → start → execute → complete.
  #
  # SIGTERM/SIGINT: stop claiming new jobs; the current job finishes its
  # in-flight step, remaining steps are skipped, and the job is reported
  # as "canceled". Exits cleanly.
  #
  # Idle polls back off from POLL_INTERVAL up to MAX_IDLE_INTERVAL. With
  # IDLE_SHUTDOWN_AFTER set, a runner that has had no job for that long stops
  # claiming, runs IDLE_SHUTDOWN_COMMAND (e.g. terminate this instance) and
  # exits, so a scale-to-zero group can shrink without cutting a job short.
  class Runner
    def initialize(config)
      @config = config
      @client = Client.new(config)
      @backoff = Backoff.new(base: config.poll_interval,
                             max: config.max_idle_interval)
      @shutdown = false
      @idle_since = monotonic
    end

    def run
      trap_signals
      log("forge-ci-runner #{VERSION} starting " \
          "(#{@config.control_plane_url}, resource_class=#{@config.resource_class || "any"})")

      until @shutdown
        payload = poll_once
        break if @shutdown

        if payload.nil?
          if idle_too_long?
            idle_shutdown
            break
          end
          pause(@backoff.tick)
          next
        end

        @backoff.reset
        run_job(payload)
        @idle_since = monotonic
      end

      log("forge-ci-runner stopped")
    end

    private

    # The claimed job's payload, or nil when there is nothing to claim or the
    # control plane could not be reached (the caller backs off either way).
    def poll_once
      @client.claim_job(@config.resource_class)
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

    def run_job(payload)
      job_id = payload["id"]
      log("claimed job ##{job_id} (#{payload["name"]})")

      executor = Executor.new(@config, @client, payload)
      @client.start_job(job_id)

      heartbeat = start_heartbeat(job_id)
      begin
        status, step_results = executor.execute(-> { @shutdown }, cancel_check: -> { @job_canceled })
        @client.complete_job(job_id, status, step_results)
        log("job ##{job_id} #{status}")
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
          log("received #{sig}; finishing current job, no new claims")
          @shutdown = true
        end
      end
    end

    def log(message)
      $stderr.puts "[forge-ci-runner] #{message}"
    end
  end
end
