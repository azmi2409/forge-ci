# frozen_string_literal: true

require "test_helper"
require "open3"

class ExecutorTest < Minitest::Test
  def executor(payload_overrides = {}, config_overrides = {})
    RecordingExecutor.new(test_config(config_overrides),
                          NullClient.new,
                          test_payload(payload_overrides))
  end

  def test_expand_workdir
    ex = executor
    assert_equal "/root/project", ex.expand_workdir("~/project")
    assert_equal "/tmp/x", ex.expand_workdir("/tmp/x")
    assert_nil ex.expand_workdir(nil)
    assert_nil ex.expand_workdir("")
  end

  def test_env_args
    ex = executor
    assert_equal ["-e", "A=1", "-e", "B=two words"],
                 ex.env_args({ "A" => "1", "B" => "two words" })
  end

  def test_primary_run_args
    ex = executor
    args = ex.primary_run_args
    assert_equal "docker", args[0]
    assert_includes args, "-d"
    assert_includes args, "--network"
    assert_includes args, "cimg/ruby:3.2"
    assert_includes args, "-e"
    assert_includes args, "RAILS_ENV=test"
    assert_includes args, "-w"
    assert_includes args, "/root/project"
    # long-lived container by default
    assert_equal ["sleep", "infinity"], args.last(2)
    # container name embeds the job id
    name_idx = args.index("--name") + 1
    assert_match(/\Aforge-ci-job-11-/, args[name_idx])
  end

  def test_service_run_args_uses_name_and_alias
    ex = executor
    name, args = ex.service_run_args(
      { "image" => "postgres:16", "name" => "db",
        "environment" => { "POSTGRES_PASSWORD" => "pw" } }, 0)
    assert_equal "db", name
    assert_includes args, "--network-alias"
    assert_includes args, "db"
    assert_includes args, "POSTGRES_PASSWORD=pw"
  end

  def test_exec_argv_splits_shell
    ex = executor
    ex.instance_variable_set(:@workdir, "/root/project")
    argv = ex.exec_argv({ "type" => "run", "shell" => "/bin/bash -eo pipefail",
                          "command" => "make test" })
    assert_equal %w[docker exec -w /root/project], argv[0, 4]
    assert_includes argv, "-e"
    tail = argv.last(5)
    assert_equal ["/bin/bash", "-eo", "pipefail", "-c", "make test"], tail
  end

  def test_execute_runs_steps_and_reports
    ex = executor
    status, results = ex.execute
    assert_equal "success", status
    assert_equal %w[checkout Bundle], results.map { |r| r["name"] }
    assert results.all? { |r| r["exit_code"] == 0 }
    assert results.all? { |r| r["started_at"] && r["finished_at"] }
  end

  def test_execute_respects_when_conditions
    ex = executor(
      { "steps" => [
        { "type" => "run", "name" => "boom", "command" => "exit 1" },
        { "type" => "run", "name" => "skip-me", "command" => "echo hi" },
        { "type" => "run", "name" => "on-fail", "command" => "echo cleanup",
          "when" => "on_fail" },
        { "type" => "run", "name" => "always", "command" => "echo always",
          "when" => "always" }
      ] }
    )
    # first exec fails
    def ex.stream_exec(argv, **)
      @commands << [:stream_exec, argv]
      argv.last == "exit 1" ? 1 : 0
    end
    status, results = ex.execute
    assert_equal "failed", status
    by_name = results.to_h { |r| [r["name"], r["exit_code"]] }
    assert_equal 1, by_name["boom"]
    assert_equal 0, by_name["skip-me"] # skipped: reported 0
    assert_equal 0, by_name["on-fail"]
    assert_equal 0, by_name["always"]
    # only 3 real execs: boom, on-fail, always (skip-me never executed)
    assert_equal 3, ex.commands.count { |c| c[0] == :stream_exec }
  end

  def test_execute_cleans_up_in_order_even_on_setup_failure
    ex = executor({}, {})
    def ex.setup_containers
      raise "pull failed"
    end
    status, _results = ex.execute
    assert_equal "failed", status
    kinds = ex.commands.map(&:first)
    assert_equal [:run_docker] * kinds.length, kinds # only cleanup ran
    rm_cmds = ex.commands.map { |c| c[1] }
    # container rm first, then network rm last
    assert_match(/forge-ci-job-11-/, rm_cmds.first[3])
    assert_equal %w[network rm], rm_cmds.last[1, 2]
  end

  def test_cleanup_runs_after_successful_execute
    ex = executor
    ex.execute
    rm_cmds = ex.commands.select { |c| c[0] == :run_docker }.map { |c| c[1] }
    # last docker call is the network removal
    assert_equal "network", rm_cmds.last[1]
    assert_equal "rm", rm_cmds.last[2]
  end

  def test_deferred_steps_skip_loudly_without_failing
    ex = executor(
      "steps" => [
        { "type" => "store_test_results", "path" => "junit" },
        { "type" => "add_ssh_keys" },
        { "type" => "run", "name" => "ok", "command" => "true" }
      ]
    )
    status, results = ex.execute
    assert_equal "success", status
    assert_equal 3, results.length
    # no docker exec for the deferred steps
    assert_equal 1, ex.commands.count { |c| c[0] == :stream_exec }
  end

  def test_cache_steps_skip_loudly_without_project_id
    ex = executor(
      "steps" => [
        { "type" => "save_cache", "keys" => ["k"], "paths" => ["vendor"] },
        { "type" => "restore_cache", "keys" => ["k"] },
        { "type" => "run", "name" => "ok", "command" => "true" }
      ]
    )
    status, results = ex.execute
    assert_equal "success", status
    assert_equal 3, results.length
    # cache steps skipped before any docker work; only the run step execs
    assert_equal 1, ex.commands.count { |c| c[0] == :stream_exec }
  end

  def test_checkout_skipped_without_repo_url
    ex = executor("steps" => [{ "type" => "checkout" }])
    status, results = ex.execute
    assert_equal "success", status
    assert_equal "checkout", results.first["name"]
    assert_equal 0, ex.commands.count { |c| c[0] == :stream_exec }
  end

  def test_checkout_with_token_uses_auth_header_not_remote_url
    token = "ghs_installationtoken1234567890"
    ex = executor("steps" => [{ "type" => "checkout" }],
                  "repository" => { "url" => "https://github.com/octo/private.git",
                                    "sha" => "abc123", "token" => token })
    status, = ex.execute
    assert_equal "success", status
    argv = ex.commands.find { |c| c[0] == :stream_exec }[1]
    assert_includes argv, "FORGE_CI_CHECKOUT_TOKEN=#{token}"
    script = argv.last
    assert_includes script, "http.extraHeader"
    assert_includes script, "remote add origin https://github.com/octo/private.git"
    refute_includes script, token
    assert_equal "[REDACTED]", ex.instance_variable_get(:@redactor).redact(token)
  end

  def test_checkout_without_token_has_no_auth
    ex = executor("steps" => [{ "type" => "checkout" }],
                  "repository" => { "url" => "https://github.com/octo/public.git", "sha" => "abc123" })
    ex.execute
    argv = ex.commands.find { |c| c[0] == :stream_exec }[1]
    refute(argv.any? { |a| a.start_with?("FORGE_CI_CHECKOUT_TOKEN") })
    refute_includes argv.last, "extraHeader"
  end

  def test_strip_userinfo
    ex = executor
    assert_equal "https://github.com/o/r.git",
                 ex.send(:strip_userinfo, "https://x-access-token:abc@github.com/o/r.git")
    assert_equal "https://github.com/o/r.git", ex.send(:strip_userinfo, "https://github.com/o/r.git")
  end

  def test_builtin_circleci_environment
    ex = executor("repository" => { "url" => "https://github.com/KilatHost/web.git", "sha" => "abc123" },
                  "workflow_run_id" => 7)
    env = ex.builtin_environment
    assert_equal "true", env["CI"]
    assert_equal "true", env["CIRCLECI"]
    assert_equal "main", env["CIRCLE_BRANCH"]
    assert_equal "abc123", env["CIRCLE_SHA1"]
    assert_equal "build", env["CIRCLE_JOB"]
    assert_equal "11", env["CIRCLE_BUILD_NUM"]
    assert_equal "7", env["CIRCLE_WORKFLOW_ID"]
    assert_equal "/root/project", env["CIRCLE_WORKING_DIRECTORY"]
    assert_equal "KilatHost", env["CIRCLE_PROJECT_USERNAME"]
    assert_equal "web", env["CIRCLE_PROJECT_REPONAME"]
    assert_equal "/tmp/forge-ci-bash-env", env["BASH_ENV"]
    args = ex.primary_run_args
    assert_includes args, "CIRCLE_SHA1=abc123"
  end

  def test_node_variables_default_to_a_single_node
    env = executor.builtin_environment
    assert_equal "0", env["CIRCLE_NODE_INDEX"]
    assert_equal "1", env["CIRCLE_NODE_TOTAL"]
  end

  def test_node_variables_for_a_parallel_job
    env = executor("node_index" => 2, "parallelism" => 4).builtin_environment
    assert_equal "2", env["CIRCLE_NODE_INDEX"]
    assert_equal "4", env["CIRCLE_NODE_TOTAL"]
  end

  def test_installs_the_circleci_helper_into_the_container
    ex = executor("steps" => [{ "type" => "run", "name" => "x", "command" => "true" }])
    ex.execute
    cp = ex.commands.find { |c| c[0] == :run_docker && c[1][1] == "cp" }
    refute_nil cp, "expected a docker cp of the circleci helper"
    assert File.executable?(cp[1][2]), "the helper must be executable"
    assert_match(%r{\Aforge-ci-job-11-\h+:/usr/local/bin/circleci\z}, cp[1][3])
  end

  def test_job_environment_wins_over_builtins
    ex = executor("environment" => { "CI" => "custom" })
    assert_equal "custom", ex.job_environment["CI"]
  end

  def test_builtins_are_not_redacted
    ex = executor("pipeline" => { "sha" => "0123456789abcdef", "branch" => "feature-long-name" })
    redactor = ex.instance_variable_get(:@redactor)
    assert_equal "feature-long-name 0123456789abcdef", redactor.redact("feature-long-name 0123456789abcdef")
  end

  def test_default_shell_is_bash_when_image_has_it
    ex = executor("steps" => [{ "type" => "run", "name" => "x", "command" => "true" }])
    ex.execute
    argv = ex.commands.find { |c| c[0] == :stream_exec }[1]
    assert_equal ["/bin/bash", "-eo", "pipefail", "-c", "true"], argv.last(5)
    assert(ex.commands.any? { |c| c[0] == :run_docker && c[1].last.include?("touch /tmp/forge-ci-bash-env") })
  end

  def test_default_shell_falls_back_to_sh
    ex = RecordingExecutor.new(test_config, NullClient.new,
                               test_payload("steps" => [{ "type" => "run", "name" => "x", "command" => "true" }]))
    def ex.run_docker(*args)
      @commands << [:run_docker, args]
      ["", args.last.to_s.include?("test -x /bin/bash") ? 1 : 0]
    end
    ex.execute
    argv = ex.commands.find { |c| c[0] == :stream_exec }[1]
    assert_equal ["/bin/sh", "-c", "true"], argv.last(3)
  end

  def test_shutdown_flag_cancels_remaining_steps
    ex = executor(
      "steps" => [
        { "type" => "run", "name" => "one", "command" => "true" },
        { "type" => "run", "name" => "two", "command" => "true" }
      ]
    )
    calls = 0
    shutdown = -> { (calls += 1) > 1 } # false for first step, true after
    status, results = ex.execute(shutdown)
    assert_equal "canceled", status
    assert_equal %w[one two], results.map { |r| r["name"] }
    assert_equal 1, ex.commands.count { |c| c[0] == :stream_exec }
  end

  def test_docker_available_returns_boolean
    result = ForgeCIRunner::Executor.docker_available?("definitely-not-docker-xyz")
    assert_equal false, result
  end

  def test_integration_hello_world
    skip "docker not available on this machine" unless docker_available?

    out, status = Open3.capture2e("docker", "run", "--rm", "hello-world")
    assert status.success?, out
    assert_match(/Hello from Docker!/, out)
  end

  # --- setup_remote_docker --------------------------------------------------

  def remote_docker_executor(allow:, trusted: true, socket: __FILE__)
    payload = test_payload("steps" => [{ "type" => "setup_remote_docker" }, { "type" => "run", "command" => "docker info" }],
                           "trusted" => trusted)
    ForgeCIRunner::Executor.new(test_config(allow_docker_socket: allow, docker_socket_path: socket),
                                NullClient.new, payload)
  end

  def test_remote_docker_mounts_the_socket_with_its_group
    ex = remote_docker_executor(allow: true)
    args = ex.primary_run_args
    assert_includes args, "#{__FILE__}:/var/run/docker.sock"
    assert_equal File.stat(__FILE__).gid.to_s, args[args.index("--group-add") + 1]
    ex.send(:check_remote_docker!) # allowed and trusted: no error
  end

  def test_jobs_without_the_step_get_no_socket
    args = executor.primary_run_args
    refute(args.any? { |a| a.include?("docker.sock") })
    refute_includes args, "--group-add"
  end

  def test_remote_docker_is_refused_unless_the_runner_allows_it
    err = assert_raises(RuntimeError) { remote_docker_executor(allow: false).send(:check_remote_docker!) }
    assert_match "ALLOW_DOCKER_SOCKET=1", err.message
  end

  def test_remote_docker_is_refused_for_fork_pull_requests
    err = assert_raises(RuntimeError) { remote_docker_executor(allow: true, trusted: false).send(:check_remote_docker!) }
    assert_match "forks", err.message
  end

  def test_allow_docker_socket_comes_from_the_environment
    on = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t", "ALLOW_DOCKER_SOCKET" => "1")
    off = ForgeCIRunner::Config.from_env("CONTROL_PLANE_URL" => "http://x", "RUNNER_TOKEN" => "t")
    assert on.allow_docker_socket
    refute off.allow_docker_socket
    assert_equal "/var/run/docker.sock", off.docker_socket_path
  end
end
