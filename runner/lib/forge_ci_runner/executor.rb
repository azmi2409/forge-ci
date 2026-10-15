# frozen_string_literal: true

require "open3"
require "shellwords"
require "securerandom"
require "time"

module ForgeCIRunner
  # Executes one claimed job in Docker containers.
  #
  # Lifecycle per job:
  #   1. pull primary + service images, create an isolated network
  #   2. start service containers, then the primary (long-lived) container
  #   3. run each step via `docker exec`, streaming redacted logs
  #   4. ALWAYS clean up containers + network (ensure blocks)
  #
  # The docker CLI is shelled out to via Open3 with argv arrays (no shell
  # interpolation). Steps share the primary container's filesystem, so
  # intra-job state just works.
  class Executor
    # Step types that need component 7 (object storage). Loudly skipped,
    # never failed — failing here would be lying about the job.
    DEFERRED_STEPS = %w[
      save_cache restore_cache
      persist_to_workspace attach_workspace
      store_artifacts store_test_results
      add_ssh_keys
    ].freeze

    Result = Struct.new(:name, :exit_code, :started_at, :finished_at, :note,
                        keyword_init: true) do
      def to_h
        { "name" => name, "exit_code" => exit_code,
          "started_at" => started_at, "finished_at" => finished_at }
      end
    end

    def initialize(config, client, payload)
      @config = config
      @client = client
      @payload = payload
      @job_id = payload["id"]
      @suffix = SecureRandom.hex(4)
      @container = "forge-ci-job-#{@job_id}-#{@suffix}"
      @network = "forge-ci-net-#{@job_id}-#{@suffix}"
      @services = []
      @environment = payload["environment"] || {}
      @redactor = Redactor.new(@environment, min_length: config.redact_min_length)
      @streamer = LogStreamer.new(client, @job_id, @redactor,
                                  chunk_size: config.log_chunk_size)
      @workdir = nil
    end

    def self.docker_available?(docker_bin = "docker")
      _out, status = Open3.capture2e(docker_bin, "info")
      status.success?
    rescue StandardError
      false
    end

    # Runs the job. Returns [status, step_results] where status is one of
    # "success" | "failed" | "canceled" and step_results matches the
    # control plane's complete contract (names follow the server's
    # `step["name"] || step["type"]` convention).
    def execute(shutdown_check = -> { false })
      results = []
      failed = false
      shutting_down = false

      begin
        log_line("[forge-ci] starting job ##{@job_id} " \
                 "(#{@payload["name"]}, sha=#{@payload.dig("pipeline", "sha")})")
        setup_containers

        StepPlanner.plan(@payload["steps"]).each do |entry|
          if shutdown_check.call
            shutting_down = true
            results << skipped_result(entry, "runner shutting down")
            next
          end

          step = entry.step
          unless StepPlanner.runnable?(step, failed)
            results << skipped_result(entry, "when=#{step["when"] || "on_success"} not satisfied")
            next
          end

          result = execute_step(step, entry)
          results << result
          failed = true unless result.exit_code.zero?
        end
      rescue StandardError => e
        log_line("[forge-ci] ERROR: #{e.class}: #{e.message}")
        failed = true
      ensure
        @streamer.flush
        cleanup_containers
      end

      status = shutting_down ? "canceled" : (failed ? "failed" : "success")
      [status, results.map(&:to_h)]
    end

    # --- docker command builders (pure; unit-tested) ---

    # Docker has no shell to expand ~. CI images run as root; expand to /root.
    def expand_workdir(path)
      return nil if path.nil? || path.empty?

      path.start_with?("~/") ? "/root/#{path[2..]}" : path
    end

    def env_args(env)
      env.flat_map { |k, v| ["-e", "#{k}=#{v}"] }
    end

    def primary_run_args
      ex = @payload["executor"] || {}
      image = ex["image"]
      raise "job payload is missing executor.image" if image.nil? || image.empty?

      args = [@config.docker_bin, "run", "-d",
              "--name", @container,
              "--network", @network]
      wd = expand_workdir(@payload["working_directory"])
      args += ["-w", wd] if wd
      args += env_args(@environment)
      args += ["--entrypoint", ex["entrypoint"]] if ex["entrypoint"]
      args << image
      # Long-lived container: steps run via `docker exec`.
      args += ex["command"] ? ["/bin/sh", "-c", ex["command"]] : ["sleep", "infinity"]
      args
    end

    # Returns [service_name, argv].
    def service_run_args(svc, index)
      name = svc["name"] || "forge-ci-svc-#{index}-#{@suffix}"
      args = [@config.docker_bin, "run", "-d",
              "--name", name,
              "--network", @network,
              "--network-alias", name]
      args += env_args(svc["environment"] || {})
      args += ["--entrypoint", svc["entrypoint"]] if svc["entrypoint"]
      args << svc["image"]
      args += ["/bin/sh", "-c", svc["command"]] if svc["command"]
      [name, args]
    end

    # argv for `docker exec` running a step's shell command.
    def exec_argv(step, detached: false)
      shell = Shellwords.split(step["shell"] || "/bin/sh")
      args = [@config.docker_bin, "exec"]
      args << "-d" if detached
      args += ["-w", @workdir] if @workdir
      args += env_args(@environment)
      args << @container
      args + shell + ["-c", step["command"].to_s]
    end

    private

    def log_line(text)
      @streamer.write("#{text}\n")
    end

    # Runs a docker CLI command, streaming combined output to the log.
    # Returns [output, exit_code].
    def run_docker(*args)
      out, status = Open3.capture2e(*args)
      @streamer.write(out) unless out.nil? || out.empty?
      [out, status.exitstatus]
    end

    def stream_exec(argv)
      exit_code = nil
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        readers = [stdout, stderr].map do |io|
          Thread.new do
            begin
              io.each_line { |line| @streamer.write(line) }
            rescue IOError
              # stream closed; done
            end
          end
        end
        readers.each(&:join)
        exit_code = wait_thr.value.exitstatus
      end
      exit_code
    end

    def setup_containers
      ex = @payload["executor"] || {}
      images = [ex["image"]] + Array(ex["secondary_images"]).map { |s| s["image"] }
      images.compact.uniq.each do |image|
        log_line("[forge-ci] pulling #{image} ...")
        _out, code = run_docker(@config.docker_bin, "pull", image)
        raise "docker pull #{image} failed (exit #{code})" unless code.zero?
      end

      log_line("[forge-ci] creating network #{@network}")
      _out, code = run_docker(@config.docker_bin, "network", "create", @network)
      raise "docker network create failed (exit #{code})" unless code.zero?

      Array(ex["secondary_images"]).each_with_index do |svc, i|
        name, args = service_run_args(svc, i)
        log_line("[forge-ci] starting service #{name} (#{svc["image"]})")
        _out, code = run_docker(*args)
        raise "service #{name} failed to start (exit #{code})" unless code.zero?

        @services << name
      end

      @workdir = expand_workdir(@payload["working_directory"])
      log_line("[forge-ci] starting primary container #{@container} (#{ex["image"]})")
      _out, code = run_docker(*primary_run_args)
      raise "primary container failed to start (exit #{code})" unless code.zero?
    end

    def cleanup_containers
      ([@container] + @services).each do |name|
        run_docker(@config.docker_bin, "rm", "-f", name)
      rescue StandardError => e
        $stderr.puts "[forge-ci-runner] cleanup: rm -f #{name} failed: #{e.message}"
      end
      run_docker(@config.docker_bin, "network", "rm", @network)
    rescue StandardError => e
      $stderr.puts "[forge-ci-runner] cleanup: network rm failed: #{e.message}"
    end

    def execute_step(step, entry)
      started_at = Time.now.utc.iso8601
      log_line("--- step: #{entry.name} (#{step["type"]}) ---")
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      exit_code =
        case step["type"]
        when "run" then execute_run(step)
        when "checkout" then execute_checkout(step)
        when *DEFERRED_STEPS then deferred_skip(step)
        else
          log_line("[forge-ci] WARNING: unknown step type #{step["type"].inspect}; skipping")
          0
        end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      log_line("--- step finished: #{entry.name} " \
               "(exit #{exit_code}, #{format("%.1f", elapsed)}s) ---")
      Result.new(name: entry.name, exit_code: exit_code,
                 started_at: started_at, finished_at: Time.now.utc.iso8601)
    end

    def execute_run(step)
      if step["background"]
        _out, code = run_docker(*exec_argv(step, detached: true))
        log_line("[forge-ci] background step launched (exit #{code})")
        return code
      end

      stream_exec(exec_argv(step))
    end

    def execute_checkout(step)
      repo = @config.checkout_repo_url
      sha = @payload.dig("pipeline", "sha")
      if repo.nil? || repo.empty?
        log_line("[forge-ci] WARNING: skipping checkout — CHECKOUT_REPO_URL is not set.")
        log_line("[forge-ci] (the claim payload carries no repo URL; see README \"Contract gaps\")")
        return 0
      end

      workdir = @workdir || "/root/project"
      target = step["path"] ? File.join(workdir, step["path"]) : workdir
      q = ->(s) { Shellwords.escape(s.to_s) }
      cmds = [
        "git init #{q.call(target)}",
        "git -C #{q.call(target)} remote add origin #{q.call(repo)} 2>/dev/null || " \
        "git -C #{q.call(target)} remote set-url origin #{q.call(repo)}",
        "git -C #{q.call(target)} fetch --depth 1 origin #{q.call(sha)}",
        "git -C #{q.call(target)} checkout #{q.call(sha)}"
      ]
      log_line("[forge-ci] cloning #{repo} @ #{sha}")
      stream_exec([@config.docker_bin, "exec", @container, "/bin/sh", "-c", cmds.join(" && ")])
    end

    def deferred_skip(step)
      log_line("[forge-ci] WARNING: #{step["type"]} needs component 7 " \
               "(object storage) — skipping loudly, not failing the job.")
      0
    end

    def skipped_result(entry, note)
      log_line("--- step skipped: #{entry.name} (#{note}) ---")
      now = Time.now.utc.iso8601
      Result.new(name: entry.name, exit_code: 0,
                 started_at: now, finished_at: now, note: note)
    end
  end
end
