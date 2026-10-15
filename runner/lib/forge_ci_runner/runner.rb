# frozen_string_literal: true

module ForgeCIRunner
  # Main daemon loop: poll → claim → start → execute → complete.
  #
  # SIGTERM/SIGINT: stop claiming new jobs; the current job finishes its
  # in-flight step, remaining steps are skipped, and the job is reported
  # as "canceled". Exits cleanly.
  class Runner
    def initialize(config)
      @config = config
      @client = Client.new(config)
      @backoff = Backoff.new(base: config.poll_interval,
                             max: config.max_idle_interval)
      @shutdown = false
    end

    def run
      trap_signals
      log("forge-ci-runner #{VERSION} starting " \
          "(#{@config.control_plane_url}, resource_class=#{@config.resource_class || "any"})")

      until @shutdown
        payload = poll_once
        next if payload.nil? || @shutdown

        @backoff.reset
        run_job(payload)
      end

      log("forge-ci-runner stopped")
    end

    private

    def poll_once
      @client.claim_job(@config.resource_class)
    rescue Client::HTTPError => e
      # Bad token: fail fast and loud instead of backing off forever.
      raise if e.code == "401"

      log("control plane error (HTTP #{e.code}); backing off")
      sleep @backoff.tick
      nil
    rescue StandardError => e
      log("poll error: #{e.class}: #{e.message}; backing off")
      sleep @backoff.tick
      nil
    end

    def run_job(payload)
      job_id = payload["id"]
      log("claimed job ##{job_id} (#{payload["name"]})")

      executor = Executor.new(@config, @client, payload)
      @client.start_job(job_id)

      heartbeat = start_heartbeat(job_id)
      begin
        status, step_results = executor.execute(-> { @shutdown })
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
      Thread.new do
        until @heartbeat_stop
          sleep @config.heartbeat_interval
          break if @heartbeat_stop

          begin
            @client.heartbeat(job_id)
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
