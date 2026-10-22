# frozen_string_literal: true

require "open3"
require "shellwords"
require "securerandom"
require "time"
require "tmpdir"
require "fileutils"
require "json"

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
    # Step types with no runner implementation yet. Loudly skipped, never
    # failed — failing here would be lying about the job.
    DEFERRED_STEPS = %w[
      store_test_results
      add_ssh_keys
    ].freeze

    # Workspaces are implemented on top of the cache API: each workflow gets
    # a reserved key namespace, plus a manifest listing the persisted roots.
    # persist_to_workspace uploads one tarball per root; attach_workspace
    # reads the manifest and extracts every root tarball at `at`.
    WORKSPACE_KEY_PREFIX = "forge-ci-workspace"

    # CircleCI's default for `run` steps when the image has bash.
    BASH_SHELL = "/bin/bash -eo pipefail"
    POSIX_SHELL = "/bin/sh"
    # Created empty at job start; bash sources it before every step, so
    # `echo 'export X=1' >> "$BASH_ENV"` carries values to later steps.
    BASH_ENV_PATH = "/tmp/forge-ci-bash-env"
    # `circleci tests glob|split|run` for test splitting (parallelism).
    CIRCLECI_CLI_SOURCE = File.expand_path("circleci_cli.sh", __dir__)
    CIRCLECI_CLI_PATH = "/usr/local/bin/circleci"
    WORKSPACE_MANIFEST_NAME = "manifest.json"

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
      @checkout_token = payload.dig("repository", "token").to_s if payload["repository"].is_a?(Hash)
      # The checkout token never enters @environment (steps must not see
      # it), but it is still redacted from logs like any secret.
      @redactor = Redactor.new(@environment.merge("__checkout_token" => @checkout_token.to_s),
                               min_length: config.redact_min_length)
      @streamer = LogStreamer.new(client, @job_id, @redactor,
                                  chunk_size: config.log_chunk_size)
      @workdir = nil
      @project_id = payload["project_id"]
      @workflow_run_id = payload["workflow_run_id"]
      @cache_store = @project_id ? CacheStore.new(@client, @project_id) : nil
      @artifact_store = ArtifactStore.new(@client, @job_id)
      @default_shell = POSIX_SHELL
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
    def execute(shutdown_check = -> { false }, cancel_check: -> { false })
      results = []
      failed = false
      shutting_down = false
      @cancel_check = cancel_check
      @job_deadline = @config.job_timeout.to_f.positive? ? monotonic + @config.job_timeout : nil

      begin
        log_line("[forge-ci] starting job ##{@job_id} " \
                 "(#{@payload["name"]}, sha=#{@payload.dig("pipeline", "sha")})")
        setup_containers

        StepPlanner.plan(@payload["steps"]).each do |entry|
          if shutdown_check.call || @cancel_check.call
            shutting_down = true
            results << skipped_result(entry, @cancel_check.call ? "job canceled" : "runner shutting down")
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

      shutting_down ||= @cancel_check.call
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

    # CircleCI-compatible built-in variables. Kept out of @environment so
    # the redactor doesn't mask branch names and SHAs; the job's own
    # environment wins on a name clash.
    def builtin_environment
      repo = @payload["repository"].is_a?(Hash) ? @payload["repository"] : {}
      repo_url = strip_userinfo(repo["url"]) unless repo["url"].to_s.empty?
      owner, name = repo_url&.match(%r{github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?\z})&.captures
      {
        "CI" => "true",
        "CIRCLECI" => "true",
        "FORGE_CI" => "true",
        "BASH_ENV" => BASH_ENV_PATH,
        "CIRCLE_BRANCH" => @payload.dig("pipeline", "branch"),
        "CIRCLE_SHA1" => @payload.dig("pipeline", "sha"),
        "CIRCLE_JOB" => @payload["name"],
        "CIRCLE_BUILD_NUM" => @job_id,
        "CIRCLE_NODE_INDEX" => @payload["node_index"] || 0,
        "CIRCLE_NODE_TOTAL" => @payload["parallelism"] || 1,
        "CIRCLE_WORKFLOW_ID" => @workflow_run_id,
        "CIRCLE_WORKING_DIRECTORY" => expand_workdir(@payload["working_directory"]),
        "CIRCLE_REPOSITORY_URL" => repo_url,
        "CIRCLE_PROJECT_USERNAME" => owner,
        "CIRCLE_PROJECT_REPONAME" => name
      }.reject { |_k, v| v.nil? || v.to_s.empty? }.transform_values(&:to_s)
    end

    def job_environment
      builtin_environment.merge(@environment)
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
      args += env_args(job_environment)
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
      shell = Shellwords.split(step["shell"] || @default_shell)
      args = [@config.docker_bin, "exec"]
      args << "-d" if detached
      args += ["-w", @workdir] if @workdir
      args += env_args(job_environment)
      args += env_args(step["environment"]) if step["environment"].is_a?(Hash)
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

    TIMEOUT_EXIT = 124
    CANCEL_EXIT = 130

    # Streams a command's output to the job log. Kills it (and returns 124)
    # when it is silent for longer than +no_output_timeout+ seconds or the job
    # deadline passes, and (returning 130) when the job is canceled.
    # The `docker exec` client is what gets killed; the process inside the
    # container dies with the job container at cleanup.
    def stream_exec(argv, no_output_timeout: @config.step_no_output_timeout)
      exit_code = nil
      last_output = monotonic
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        readers = [stdout, stderr].map do |io|
          Thread.new do
            begin
              io.each_line do |line|
                last_output = monotonic
                @streamer.write(line)
              end
            rescue IOError
              # stream closed; done
            end
          end
        end

        reason = nil
        until wait_thr.join(0.5)
          now = monotonic
          if @cancel_check&.call
            reason = :canceled
          elsif no_output_timeout.to_f.positive? && now - last_output > no_output_timeout
            reason = :no_output
          elsif @job_deadline && now > @job_deadline
            reason = :job_timeout
          end
          next unless reason

          kill_process(wait_thr)
          # A grandchild may still hold the pipes open; don't wait on it.
          [stdout, stderr].each { |io| io.close unless io.closed? }
          break
        end

        readers.each { |t| t.join(5) }
        status = wait_thr.value
        exit_code = status.exitstatus || TIMEOUT_EXIT
        case reason
        when :canceled
          log_line("[forge-ci] step stopped: job was canceled")
          exit_code = CANCEL_EXIT
        when :no_output
          log_line("[forge-ci] step killed: no output for #{no_output_timeout.to_i}s (no_output_timeout)")
          exit_code = TIMEOUT_EXIT
        when :job_timeout
          log_line("[forge-ci] step killed: job exceeded #{@config.job_timeout.to_i}s (JOB_TIMEOUT)")
          exit_code = TIMEOUT_EXIT
        end
      end
      exit_code
    end

    def kill_process(wait_thr)
      Process.kill("TERM", wait_thr.pid)
      return if wait_thr.join(5)

      Process.kill("KILL", wait_thr.pid)
    rescue Errno::ESRCH
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # "30s" / "10m" / "1h" / bare seconds -> seconds (nil when unparseable).
    def parse_duration(value)
      m = value.to_s.strip.match(/\A(\d+(?:\.\d+)?)([smh]?)\z/)
      return nil unless m

      m[1].to_f * { "" => 1, "s" => 1, "m" => 60, "h" => 3600 }.fetch(m[2])
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

      prepare_shell
      install_circleci_cli
    end

    # Copies the `circleci tests` helper into the job container (docker cp
    # writes as root, so this works for non-root images too). A failure only
    # costs test splitting, so it warns instead of failing the job.
    def install_circleci_cli
      _out, code = run_docker(@config.docker_bin, "cp", CIRCLECI_CLI_SOURCE, "#{@container}:#{CIRCLECI_CLI_PATH}")
      return if code.zero?

      log_line("[forge-ci] WARNING: could not install #{CIRCLECI_CLI_PATH}; `circleci tests` won't be available")
    end

    # Pick the default `run` shell (bash when the image has it, like
    # CircleCI) and create the empty $BASH_ENV file.
    def prepare_shell
      _out, code = run_docker(@config.docker_bin, "exec", @container, "/bin/sh", "-c",
                              "touch #{BASH_ENV_PATH} && test -x /bin/bash")
      @default_shell = code.zero? ? BASH_SHELL : POSIX_SHELL
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
        when "save_cache" then execute_save_cache(step)
        when "restore_cache" then execute_restore_cache(step)
        when "store_artifacts" then execute_store_artifacts(step)
        when "persist_to_workspace" then execute_persist_workspace(step)
        when "attach_workspace" then execute_attach_workspace(step)
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

      timeout = parse_duration(step["no_output_timeout"]) || @config.step_no_output_timeout
      stream_exec(exec_argv(step), no_output_timeout: timeout)
    end

    def execute_checkout(step)
      repo_info = @payload["repository"]
      repo_info = {} unless repo_info.is_a?(Hash)
      repo = repo_info["url"] || @config.checkout_repo_url
      sha = repo_info["sha"] || @payload.dig("pipeline", "sha")
      if repo.nil? || repo.empty?
        log_line("[forge-ci] WARNING: skipping checkout — no repository.url in " \
                 "the claim payload and CHECKOUT_REPO_URL is not set.")
        return 0
      end

      workdir = @workdir || "/root/project"
      target = step["path"] ? File.join(workdir, step["path"]) : workdir
      q = ->(s) { Shellwords.escape(s.to_s) }
      # A GitHub App installation token (private repos) is passed as an env
      # var on this one exec (the same way step env reaches `docker exec`)
      # and sent as an HTTP header for the fetch only, so it never lands in
      # .git/config or any step's environment.
      fetch = "git -C #{q.call(target)} fetch --depth 1 origin #{q.call(sha)}"
      if @checkout_token.to_s.empty?
        env = []
      else
        env = ["-e", "FORGE_CI_CHECKOUT_TOKEN=#{@checkout_token}"]
        fetch = "git -C #{q.call(target)} -c http.extraHeader=\"Authorization: Basic " \
                "$(printf 'x-access-token:%s' \"$FORGE_CI_CHECKOUT_TOKEN\" | base64 | tr -d '\\n')\" " \
                "fetch --depth 1 origin #{q.call(sha)}"
      end
      cmds = [
        "git init #{q.call(target)}",
        "git -C #{q.call(target)} remote add origin #{q.call(repo)} 2>/dev/null || " \
        "git -C #{q.call(target)} remote set-url origin #{q.call(repo)}",
        fetch,
        "git -C #{q.call(target)} checkout #{q.call(sha)}"
      ]
      log_line("[forge-ci] cloning #{strip_userinfo(repo)} @ #{sha}")
      stream_exec([@config.docker_bin, "exec", *env, @container, "/bin/sh", "-c", cmds.join(" && ")])
    end

    # https://user:token@host/x.git -> https://host/x.git (for log lines).
    def strip_userinfo(url)
      url.to_s.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, '\\1')
    end

    # --- cache / artifacts / workspaces (object storage is live) ---

    # Warns + returns 0. Cache steps address the project-scoped cache API,
    # which needs project_id from the claim payload.
    def warn_zero(message)
      log_line("[forge-ci] WARNING: #{message}")
      0
    end

    def require_project_id(step)
      return @project_id unless @project_id.nil?

      log_line("[forge-ci] WARNING: skipping #{step["type"]} — the claim payload " \
               "carries no project_id, so the cache API cannot be addressed. " \
               "(The control plane should include project_id in the job payload.)")
      nil
    end

    def resolve_key(template)
      KeyTemplate.resolve(
        template,
        branch: @payload.dig("pipeline", "branch"),
        checksum: ->(rel) { container_sha256(rel) },
        warn: ->(m) { log_line("[forge-ci] WARNING: cache key: #{m}") }
      )
    end

    # SHA256 of a file inside the primary container (path relative to the
    # job working directory). Nil when missing/unreadable. Silent: query
    # output must not pollute the job log.
    def container_sha256(relative_path)
      workdir = @workdir || "/root/project"
      target = File.join(workdir, relative_path)
      out, status = capture_silent(@config.docker_bin, "exec", @container,
                                   "sha256sum", "--", target)
      return nil unless status.success?

      out.split.first
    rescue StandardError
      nil
    end

    # Open3 without streaming to the job log (small queries like sha256sum).
    def capture_silent(*args)
      Open3.capture2e(*args)
    end

    # Pure argv builders for container-side tar (unit-tested).
    def tar_create_argv(tgz, paths, base_dir)
      [@config.docker_bin, "exec", @container, "tar", "-czf", tgz,
       "-C", base_dir, *paths]
    end

    def tar_extract_argv(tgz, dest_dir)
      [@config.docker_bin, "exec", @container, "tar", "-xzf", tgz,
       "-C", dest_dir]
    end

    # Copies a container-side tarball to a host temp dir. Returns the host
    # path; the caller owns the temp dir (delete it when done). When
    # +host_dir+ is given the tarball lands there instead of a fresh dir.
    def fetch_tarball(container_tgz, host_dir = nil)
      host_dir ||= Dir.mktmpdir("forge-ci-fetch")
      host_tgz = File.join(host_dir, File.basename(container_tgz))
      _out, code = run_docker(@config.docker_bin, "cp",
                              "#{@container}:#{container_tgz}", host_tgz)
      raise "docker cp from container failed (exit #{code})" unless code.zero?

      host_tgz
    end

    # Copies a host tarball into the container. Returns the container path.
    def send_tarball(host_tgz)
      container_tgz = "/tmp/forge-ci-send-#{SecureRandom.hex(6)}.tgz"
      _out, code = run_docker(@config.docker_bin, "cp",
                              host_tgz, "#{@container}:#{container_tgz}")
      raise "docker cp to container failed (exit #{code})" unless code.zero?

      container_tgz
    end

    def execute_save_cache(step)
      return 0 unless require_project_id(step)

      key = resolve_key(step["keys"]&.first || step["key"])
      return warn_zero("save_cache has no usable key; skipping") if key.nil? || key.empty?

      paths = Array(step["paths"]).map(&:to_s).reject(&:empty?)
      return warn_zero("save_cache has no paths; skipping") if paths.empty?

      workdir = @workdir || "/root/project"
      container_tgz = "/tmp/forge-ci-cache-#{SecureRandom.hex(6)}.tgz"
      _out, code = run_docker(*tar_create_argv(container_tgz, paths, workdir))
      return warn_zero("save_cache: tar of cache paths failed (exit #{code})") unless code.zero?

      host_tgz = nil
      begin
        host_tgz = fetch_tarball(container_tgz)
        resp = @cache_store.save(key, host_tgz)
        log_line("[forge-ci] save_cache: stored key #{key} (#{resp["size"]} bytes)")
      rescue StandardError => e
        return warn_zero("save_cache failed: #{e.class}: #{e.message}")
      ensure
        run_docker(@config.docker_bin, "exec", @container, "rm", "-f", container_tgz)
        FileUtils.rm_rf(File.dirname(host_tgz)) if host_tgz
      end
      0
    end

    def execute_restore_cache(step)
      return 0 unless require_project_id(step)

      keys = Array(step["keys"]).map(&:to_s).reject(&:empty?)
      return warn_zero("restore_cache has no keys; skipping") if keys.empty?

      resolved = keys.map { |k| resolve_key(k) }.reject(&:empty?)
      log_line("[forge-ci] restore_cache: trying #{resolved.join(", ")}")

      host_tgz = @cache_store.restore(resolved)
      if host_tgz.nil?
        log_line("[forge-ci] restore_cache: no matching cache entry (miss).")
        return 0
      end

      workdir = @workdir || "/root/project"
      container_tgz = nil
      begin
        container_tgz = send_tarball(host_tgz)
        _out, code = run_docker(*tar_extract_argv(container_tgz, workdir))
        return warn_zero("restore_cache: extract failed (exit #{code})") unless code.zero?

        log_line("[forge-ci] restore_cache: hit, extracted into #{workdir}")
      rescue StandardError => e
        return warn_zero("restore_cache failed: #{e.class}: #{e.message}")
      ensure
        if container_tgz
          run_docker(@config.docker_bin, "exec", @container, "rm", "-f", container_tgz)
        end
        FileUtils.rm_rf(File.dirname(host_tgz)) if host_tgz
      end
      0
    end

    def execute_store_artifacts(step)
      src = step["path"].to_s
      return warn_zero("store_artifacts has no path; skipping") if src.empty?

      destination = step["destination"]
      workdir = @workdir || "/root/project"
      container_tgz = "/tmp/forge-ci-artifacts-#{SecureRandom.hex(6)}.tgz"
      _out, code = run_docker(*tar_create_argv(container_tgz, [src], workdir))
      return warn_zero("store_artifacts: could not archive #{src} (exit #{code})") unless code.zero?

      host_dir = Dir.mktmpdir("forge-ci-artifacts")
      begin
        host_tgz = fetch_tarball(container_tgz, host_dir)
        files_dir = File.join(host_dir, "files")
        Tarball.extract(host_tgz, dest_dir: files_dir)
        files = Dir.glob(File.join(files_dir, "**", "*")).select { |f| File.file?(f) }
        return warn_zero("store_artifacts: nothing found at #{src}") if files.empty?

        files.each do |f|
          rel = f.sub("#{files_dir}/", "")
          resp = @artifact_store.upload(f, path: rel, destination: destination)
          suffix = destination.to_s.empty? ? "" : " -> #{destination}"
          log_line("[forge-ci] artifact stored: #{rel}#{suffix} (#{resp["size"]} bytes)")
        end
      rescue StandardError => e
        return warn_zero("store_artifacts failed: #{e.class}: #{e.message}")
      ensure
        run_docker(@config.docker_bin, "exec", @container, "rm", "-f", container_tgz)
        FileUtils.rm_rf(host_dir) if host_dir
      end
      0
    end

    # Workspace key layout (documented in README): one reserved cache
    # namespace per workflow, one tarball per persisted root, plus a
    # manifest.json listing the roots so attach_workspace can discover
    # them. attach extracts every root tarball at `at`.
    def workspace_key_prefix
      "#{WORKSPACE_KEY_PREFIX}/#{@workflow_run_id}"
    end

    def workspace_manifest_key
      "#{workspace_key_prefix}/#{WORKSPACE_MANIFEST_NAME}"
    end

    def workspace_root_key(root)
      safe = root.to_s.gsub(%r{\A\./}, "").gsub(/[^A-Za-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      safe = "root" if safe.empty?
      "#{workspace_key_prefix}/#{safe}.tgz"
    end

    def workspace_manifest
      hit = @client.get_cache(@project_id, [workspace_manifest_key])
      return [] if hit.nil? || hit["download_url"].to_s.empty?

      dir = Dir.mktmpdir("forge-ci-ws-manifest")
      begin
        dest = File.join(dir, "manifest.json")
        @client.download(hit["download_url"], dest)
        JSON.parse(File.read(dest))
      rescue StandardError => e
        log_line("[forge-ci] WARNING: workspace manifest unreadable (#{e.message}); starting fresh")
        []
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    def save_workspace_manifest(roots)
      dir = Dir.mktmpdir("forge-ci-ws-manifest")
      begin
        path = File.join(dir, "manifest.json")
        File.write(path, JSON.generate(roots.uniq))
        @client.put_cache(@project_id, workspace_manifest_key, path)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    def execute_persist_workspace(step)
      return 0 unless require_project_id(step)
      return warn_zero("persist_to_workspace: no workflow_run_id in payload; skipping") if @workflow_run_id.nil?

      root = step["root"].to_s
      paths = Array(step["paths"]).map(&:to_s).reject(&:empty?)
      return warn_zero("persist_to_workspace needs root and paths; skipping") if root.empty? || paths.empty?

      base_dir = File.join(@workdir || "/root/project", root)
      container_tgz = "/tmp/forge-ci-ws-#{SecureRandom.hex(6)}.tgz"
      _out, code = run_docker(*tar_create_argv(container_tgz, paths, base_dir))
      return warn_zero("persist_to_workspace: tar failed (exit #{code})") unless code.zero?

      host_tgz = nil
      begin
        host_tgz = fetch_tarball(container_tgz)
        key = workspace_root_key(root)
        resp = @cache_store.save(key, host_tgz)
        save_workspace_manifest(workspace_manifest + [root])
        log_line("[forge-ci] persist_to_workspace: stored #{paths.join(", ")} " \
                 "as #{key} (#{resp["size"]} bytes)")
      rescue StandardError => e
        return warn_zero("persist_to_workspace failed: #{e.class}: #{e.message}")
      ensure
        run_docker(@config.docker_bin, "exec", @container, "rm", "-f", container_tgz)
        FileUtils.rm_rf(File.dirname(host_tgz)) if host_tgz
      end
      0
    end

    def execute_attach_workspace(step)
      return 0 unless require_project_id(step)
      return warn_zero("attach_workspace: no workflow_run_id in payload; skipping") if @workflow_run_id.nil?

      at = step["at"].to_s
      return warn_zero("attach_workspace needs an 'at' path; skipping") if at.empty?

      roots = workspace_manifest
      if roots.empty?
        log_line("[forge-ci] attach_workspace: workspace is empty; nothing to attach.")
        return 0
      end

      dest_base = File.join(@workdir || "/root/project", at)
      run_docker(@config.docker_bin, "exec", @container, "mkdir", "-p", dest_base)

      roots.each do |root|
        key = workspace_root_key(root)
        host_tgz = @cache_store.restore([key])
        if host_tgz.nil?
          log_line("[forge-ci] WARNING: attach_workspace: missing tarball for " \
                   "root #{root.inspect}; skipping it.")
          next
        end
        container_tgz = nil
        begin
          container_tgz = send_tarball(host_tgz)
          _out, code = run_docker(*tar_extract_argv(container_tgz, dest_base))
          if code.zero?
            log_line("[forge-ci] attach_workspace: attached #{root} at #{at}")
          else
            log_line("[forge-ci] WARNING: attach_workspace: extract of #{root} " \
                     "failed (exit #{code})")
          end
        ensure
          if container_tgz
            run_docker(@config.docker_bin, "exec", @container, "rm", "-f", container_tgz)
          end
          FileUtils.rm_rf(File.dirname(host_tgz)) if host_tgz
        end
      end
      0
    rescue StandardError => e
      warn_zero("attach_workspace failed: #{e.class}: #{e.message}")
    end

    def deferred_skip(step)
      log_line("[forge-ci] WARNING: #{step["type"]} is not implemented yet — " \
               "skipping loudly, not failing the job.")
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
