# frozen_string_literal: true

module ForgeCIRunner
  # Runner configuration, read from the environment.
  #
  # Required:
  #   CONTROL_PLANE_URL  base URL of the forge-ci control plane, e.g. https://ci.example.com
  #   RUNNER_TOKEN       shared runner secret — set the SAME value as the
  #                        server's FORGE_CI_RUNNER_TOKEN (pick any strong
  #                        random string, e.g. `openssl rand -hex 32`)
  #
  #   (or RUNNER_TOKEN_FILE  a file holding it, e.g. the control plane's
  #                        runner-token on a shared volume)
  #
  # Optional:
  #   RESOURCE_CLASS       resource class this runner serves (default: token's class)
  #   POLL_INTERVAL        seconds between claim polls when idle (default: 5)
  #   MAX_IDLE_INTERVAL    cap for idle backoff (default: 60)
  #   HEARTBEAT_INTERVAL   seconds between heartbeats while a job runs (default: 15)
  #   LOG_CHUNK_SIZE       bytes per log chunk POSTed to the server (default: 65536)
  #   CHECKOUT_REPO_URL    fallback git URL for `checkout` steps when the claim
  #                        payload has no repository.url; may embed a token, e.g.
  #                        https://x-access-token:TOKEN@github.com/org/repo.git
  #   REDACT_MIN_LENGTH    env values shorter than this are not redacted (default: 8)
  #   DOCKER_BIN           path to the docker CLI (default: "docker")
#   BUILDX_BIN           path to a buildx binary (e.g. /opt/forge-ci-runner/bin/buildx,
#                        installed by the installer) that gets copied into job
#                        containers lacking one, for docker_layer_caching builds
#                        (unset: such jobs warn and build without a shared cache)
  #   STEP_NO_OUTPUT_TIMEOUT  seconds a `run` step may stay silent before it is
  #                        killed (default: 600, like CircleCI; a step's own
  #                        `no_output_timeout:` overrides it; 0 disables)
  #   JOB_TIMEOUT          wall-clock seconds a whole job may run (default: 3600;
  #                        0 disables)
  #   IDLE_SHUTDOWN_AFTER  seconds without a job after which the runner stops
  #                        claiming, runs IDLE_SHUTDOWN_COMMAND and exits
  #                        (default: 0, never). For scale-to-zero groups.
  #   IDLE_LINGER_MAX      extra seconds to stay after base idle when the
  #                        control plane reports expected work (default: 0).
  #   IDLE_OUTLOOK_INTERVAL seconds between claim/outlook polls while lingering
  #                        (default: 15).
  #   IDLE_SHUTDOWN_COMMAND shell command run once on idle shutdown, e.g.
  #                        bin/forge-ci-asg-terminate-self (optional)
  #   REQUEUE_ON_SHUTDOWN  1 = on SIGTERM/SIGINT mid-job, stop the running step
  #                        and hand the job back to the queue instead of
  #                        reporting it canceled (default: off). For Spot or
  #                        preemptible runners whose jobs are safe to retry;
  #                        never on deploy runners.
  class Config
    class Error < StandardError; end

    attr_reader :control_plane_url, :runner_token, :resource_class,
                :poll_interval, :max_idle_interval, :heartbeat_interval,
                :log_chunk_size, :log_flush_interval, :checkout_repo_url, :redact_min_length,
                :docker_bin, :buildx_bin, :step_no_output_timeout, :job_timeout,
                :idle_shutdown_after, :idle_shutdown_command, :idle_linger_max, :idle_outlook_interval,
                :allow_docker_socket, :docker_socket_path, :requeue_on_shutdown

    def self.from_env(env = ENV)
      new(
        control_plane_url: fetch_required(env, "CONTROL_PLANE_URL").sub(%r{/+\z}, ""),
        runner_token: runner_token_from(env),
        resource_class: env["RESOURCE_CLASS"].to_s.empty? ? nil : env["RESOURCE_CLASS"],
        poll_interval: (env["POLL_INTERVAL"] || 5).to_f,
        max_idle_interval: (env["MAX_IDLE_INTERVAL"] || 60).to_f,
        heartbeat_interval: (env["HEARTBEAT_INTERVAL"] || 15).to_f,
        log_chunk_size: (env["LOG_CHUNK_SIZE"] || 65_536).to_i,
        log_flush_interval: (env["LOG_FLUSH_INTERVAL"] || 1).to_f,
        checkout_repo_url: env["CHECKOUT_REPO_URL"],
        redact_min_length: (env["REDACT_MIN_LENGTH"] || 8).to_i,
        docker_bin: env["DOCKER_BIN"] || "docker",
        buildx_bin: env["BUILDX_BIN"].to_s.empty? ? nil : env["BUILDX_BIN"],
        step_no_output_timeout: (env["STEP_NO_OUTPUT_TIMEOUT"] || 600).to_f,
        job_timeout: (env["JOB_TIMEOUT"] || 3600).to_f,
        idle_shutdown_after: (env["IDLE_SHUTDOWN_AFTER"] || 0).to_f,
        idle_linger_max: (env["IDLE_LINGER_MAX"] || 0).to_f,
        idle_outlook_interval: (env["IDLE_OUTLOOK_INTERVAL"] || 15).to_f,
        idle_shutdown_command: env["IDLE_SHUTDOWN_COMMAND"],
        allow_docker_socket: %w[1 true yes].include?(env["ALLOW_DOCKER_SOCKET"].to_s.strip.downcase),
        docker_socket_path: env["DOCKER_SOCKET_PATH"].to_s.empty? ? "/var/run/docker.sock" : env["DOCKER_SOCKET_PATH"],
        requeue_on_shutdown: %w[1 true yes].include?(env["REQUEUE_ON_SHUTDOWN"].to_s.strip.downcase)
      )
    end

    def self.runner_token_from(env)
      return env["RUNNER_TOKEN"] unless env["RUNNER_TOKEN"].to_s.empty?

      path = env["RUNNER_TOKEN_FILE"].to_s
      return fetch_required(env, "RUNNER_TOKEN") if path.empty?

      File.read(path).strip
    rescue SystemCallError => e
      raise Error, "RUNNER_TOKEN_FILE #{path}: #{e.message}"
    end
    private_class_method :runner_token_from

    def self.fetch_required(env, key)
      env.fetch(key) { raise Error, "#{key} is required" }
    end
    private_class_method :fetch_required

    def initialize(control_plane_url:, runner_token:, resource_class: nil,
                   poll_interval: 5.0, max_idle_interval: 60.0,
                   heartbeat_interval: 15.0, log_chunk_size: 65_536, log_flush_interval: 1.0,
                   checkout_repo_url: nil, redact_min_length: 8,
                   docker_bin: "docker", buildx_bin: nil, step_no_output_timeout: 600.0,
                   job_timeout: 3600.0, idle_shutdown_after: 0.0,
                   idle_linger_max: 0.0, idle_outlook_interval: 15.0,
                   idle_shutdown_command: nil, allow_docker_socket: false,
                   docker_socket_path: "/var/run/docker.sock", requeue_on_shutdown: false)
      raise Error, "CONTROL_PLANE_URL is required" if control_plane_url.to_s.empty?
      if runner_token.to_s.empty?
        raise Error, "RUNNER_TOKEN is required — set it to the same secret as " \
                     "the server's FORGE_CI_RUNNER_TOKEN (e.g. `openssl rand -hex 32`)"
      end

      @control_plane_url = control_plane_url.sub(%r{/+\z}, "")
      @runner_token = runner_token
      @resource_class = resource_class
      @poll_interval = poll_interval
      @max_idle_interval = max_idle_interval
      @heartbeat_interval = heartbeat_interval
      @log_chunk_size = log_chunk_size
      @log_flush_interval = log_flush_interval
      @checkout_repo_url = checkout_repo_url
      @redact_min_length = redact_min_length
      @docker_bin = docker_bin
      @buildx_bin = buildx_bin
      @step_no_output_timeout = step_no_output_timeout
      @job_timeout = job_timeout
      @idle_shutdown_after = idle_shutdown_after
      @idle_linger_max = idle_linger_max
      @idle_outlook_interval = idle_outlook_interval.to_f.positive? ? idle_outlook_interval.to_f : 15.0
      @idle_shutdown_command = idle_shutdown_command
      @allow_docker_socket = allow_docker_socket
      @docker_socket_path = docker_socket_path
      @requeue_on_shutdown = requeue_on_shutdown
    end
  end
end
