# frozen_string_literal: true

require "test_helper"

# Registry-backed layer cache: env injection into the job container, the
# argv builders, and the setup_remote_docker prepare sequence.
class DockerLayerCacheTest < Minitest::Test
  CACHE = { "registry" => "123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache",
            "ref" => "123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache:p7-main",
            "username" => "AWS",
            "password" => "ecr-token-long-secret" }.freeze

  def cache_payload(overrides = {})
    test_payload({ "docker_build_cache" => CACHE.dup,
                   "steps" => [{ "type" => "setup_remote_docker", "layer_caching" => true },
                               { "type" => "run", "name" => "Build", "command" => "forge-ci-build -t app ." }] }
                        .merge(overrides))
  end

  def executor(payload_overrides = {}, config_overrides = {})
    ScriptedExecutor.new(test_config(config_overrides), NullClient.new,
                         cache_payload(payload_overrides))
  end

  # RecordingExecutor whose run_docker exits with scripted codes, keyed by a
  # fragment of the command ("login", "buildx create", ...). Unscripted
  # commands succeed.
  class ScriptedExecutor < RecordingExecutor
    attr_reader :exit_codes

    def initialize(*args, exit_codes: {})
      super(*args)
      @script = exit_codes
    end

    private

    def run_docker(*args)
      command = args.join(" ")
      @commands << [:run_docker, args]
      ["", @script.find { |frag, _code| command.include?(frag) }&.last || 0]
    end
  end

  def docker_commands(ex)
    ex.commands.select { |kind, _| kind == :run_docker }.map { |_, args| args.join(" ") }
  end

  # --- env injection ----------------------------------------------------------

  def test_cache_env_reaches_the_container_only_for_layer_caching_jobs
    args = executor.primary_run_args
    %w[FORGE_CI_BUILD_CACHE_REGISTRY FORGE_CI_BUILD_CACHE_FROM FORGE_CI_BUILD_CACHE_TO
       FORGE_CI_BUILD_BUILDER FORGE_CI_BUILD_CACHE_USERNAME FORGE_CI_BUILD_CACHE_PASSWORD].each do |key|
      assert(args.any? { |a| a.to_s.start_with?("#{key}=") }, "#{key} missing")
    end
    assert_includes args, "FORGE_CI_BUILD_CACHE_FROM=#{CACHE["ref"]}"
    assert_includes args, "FORGE_CI_BUILD_CACHE_TO=#{CACHE["ref"]}"
  end

  def test_builder_name_matches_the_job
    ex = executor
    assert_includes ex.build_cache_environment["FORGE_CI_BUILD_BUILDER"], "forge-ci-bx-11-"
    assert_match(/\Abuildx_buildkit_forge-ci-bx-11-[0-9a-f]{8}0\z/, ex.buildx_builder_container)
  end

  def test_no_cache_env_without_the_flag_or_the_payload_section
    no_flag = executor("steps" => [{ "type" => "setup_remote_docker" },
                                   { "type" => "run", "command" => "docker build ." }])
    no_section = executor("docker_build_cache" => nil)
    [no_flag, no_section].each do |ex|
      env = ex.build_cache_environment
      assert_empty env
      refute(ex.primary_run_args.any? { |a| a.to_s.start_with?("FORGE_CI_BUILD_") })
    end
  end

  def test_job_environment_wins_over_cache_env
    ex = executor("environment" => { "FORGE_CI_BUILD_CACHE_TO" => "my-own-ref",
                                     "RAILS_ENV" => "test" })
    assert_includes ex.job_environment["FORGE_CI_BUILD_CACHE_TO"], "my-own-ref"
  end

  def test_the_registry_password_is_redacted_from_logs
    ex = executor
    redactor = ex.instance_variable_get(:@redactor)
    assert_equal "docker login -u AWS --password-stdin ... [REDACTED]",
                 redactor.redact("docker login -u AWS --password-stdin ... #{CACHE["password"]}")
  end

  # --- argv builders ----------------------------------------------------------

  def test_login_runs_inside_the_container_without_the_password_in_argv
    argv = executor.cache_login_argv
    assert_equal %w[docker exec], argv[0, 2]
    assert(argv.any? { |a| a.to_s.start_with?("forge-ci-job-11-") }, "runs against the job container")
    # The password travels as a -e env element (like the checkout token), and
    # the shell command references it by name — never inline.
    assert_includes argv, "FORGE_CI_BUILD_CACHE_PASSWORD=#{CACHE["password"]}"
    refute(argv.last.include?(CACHE["password"]), "the shell command must not embed the password")
    assert_match(/docker login --password-stdin/, argv.last)
  end

  def test_builder_is_created_without_use
    argv = executor.buildx_create_argv
    assert_equal ["docker", "exec"], argv[0, 2]
    assert_includes argv, "buildx"
    assert_includes argv, "create"
    assert_includes argv, "docker-container"
    refute_includes argv, "--use", "a default builder would change plain `docker build` semantics"
  end

  def test_buildx_and_wrapper_are_copied_to_docker_cli_paths
    ex = ForgeCIRunner::Executor.new(test_config(buildx_bin: "/opt/forge-ci-runner/bin/buildx"),
                                     NullClient.new, cache_payload)
    container = ex.instance_variable_get(:@container)
    assert_equal ["docker", "cp", "/opt/forge-ci-runner/bin/buildx",
                  "#{container}:/usr/local/lib/docker/cli-plugins/docker-buildx"],
                 ex.buildx_cp_argv
    assert_match(%r{docker_build_wrapper\.sh}, ex.wrapper_cp_argv[2])
    assert_equal "#{container}:/usr/local/bin/forge-ci-build", ex.wrapper_cp_argv[3]
  end

  # --- setup_remote_docker behavior -------------------------------------------

  def test_prepare_build_cache_full_sequence_and_cleanup
    ex = executor({}, allow_docker_socket: true)
    status, = ex.execute
    commands = docker_commands(ex)
    assert_equal "success", status
    assert(commands.any? { |c| c.include?("docker login") }, "expected a registry login")
    assert(commands.any? { |c| c.include?("docker buildx version") }, "expected a buildx check")
    assert(commands.any? { |c| c.include?("buildx create --name forge-ci-bx-11-") })
    assert(commands.any? { |c| c.include?("forge-ci-build") && c.include?(" cp ") })
    assert(commands.any? { |c| c.include?("rm -f buildx_buildkit_forge-ci-bx-11-") },
           "the builder container must be removed with the job")
  end

  def test_buildx_is_copied_in_when_the_image_has_none
    ex = executor({}, buildx_bin: "/opt/forge-ci-runner/bin/buildx")
    # First buildx check fails (no buildx in the image), the re-check passes.
    ex.define_singleton_method(:run_docker) do |*args|
      command = args.join(" ")
      checks = @commands.count { |_, a| a.join(" ").include?("buildx version") }
      code = command.include?("buildx version") && checks.zero? ? 1 : 0
      @commands << [:run_docker, args]
      ["", code]
    end
    ex.send(:execute_setup_remote_docker, { "layer_caching" => true })
    commands = docker_commands(ex)
    assert(commands.any? { |c| c.include?("mkdir -p /usr/local/lib/docker/cli-plugins") })
    assert(commands.any? { |c| c.include?("cp /opt/forge-ci-runner/bin/buildx") })
    assert(commands.any? { |c| c.include?("chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx") })
    assert(commands.any? { |c| c.include?("buildx create") }, "setup continues after the copy")
  end

  def test_missing_buildx_without_buildx_bin_gives_up_on_the_cache
    ex = executor
    ex.define_singleton_method(:run_docker) do |*args|
      command = args.join(" ")
      code = command.include?("buildx version") ? 1 : 0
      @commands << [:run_docker, args]
      ["", code]
    end
    ex.send(:execute_setup_remote_docker, { "layer_caching" => true })
    commands = docker_commands(ex)
    assert(commands.any? { |c| c.include?("buildx version") })
    assert_empty(commands.grep(/buildx create|cli-plugins/), "no builder, no copy: just warn")
  end

  def test_layer_caching_without_a_server_registry_warns_and_builds_uncached
    ex = executor("docker_build_cache" => nil)
    result = ex.send(:execute_setup_remote_docker, { "layer_caching" => true })
    assert_equal 0, result, "a missing server config must not fail the job"
    assert_empty(docker_commands(ex).grep(/login|buildx|forge-ci-build/))
  end

  def test_plain_setup_remote_docker_without_the_flag_never_prepares_cache
    ex = executor
    result = ex.send(:execute_setup_remote_docker, {})
    assert_equal 0, result
    assert_empty(docker_commands(ex).grep(/login|buildx|forge-ci-build/))
  end

  def test_failed_login_skips_the_rest_of_the_cache_setup
    ex = ScriptedExecutor.new(test_config({}), NullClient.new, cache_payload,
                              exit_codes: { "docker login" => 1 })
    ex.send(:execute_setup_remote_docker, { "layer_caching" => true })
    commands = docker_commands(ex)
    assert(commands.any? { |c| c.include?("docker login") })
    assert_empty(commands.grep(/buildx create|forge-ci-build/))
  end

  def test_unauthenticated_registry_skips_login
    payload = cache_payload("docker_build_cache" => CACHE.merge("username" => nil, "password" => nil))
    ex = ScriptedExecutor.new(test_config({}), NullClient.new, payload)
    ex.send(:execute_setup_remote_docker, { "layer_caching" => true })
    commands = docker_commands(ex)
    assert_empty(commands.grep(/docker login/), "no credentials: nothing to log in to")
    assert(commands.any? { |c| c.include?("buildx create") }, "setup continues without login")
  end

  def test_buildx_bin_comes_from_the_environment
    on = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t",
                                        "BUILDX_BIN" => "/opt/forge-ci-runner/bin/buildx")
    off = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t")
    assert_equal "/opt/forge-ci-runner/bin/buildx", on.buildx_bin
    assert_nil off.buildx_bin
  end
end
