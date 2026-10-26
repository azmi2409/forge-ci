# frozen_string_literal: true

require "test_helper"
require "forge_ci/cli"
require "stringio"
require "tmpdir"

class CLITest < Minitest::Test
  def run_cli(*args)
    out = StringIO.new
    err = StringIO.new
    status = ForgeCI::CLI.run(args, out: out, err: err)
    [status, out.string, err.string]
  end

  def fixture_path(name)
    File.join(FIXTURES_DIR, name)
  end

  # -- top-level flags -------------------------------------------------------

  def test_help_exits_zero_and_shows_usage
    status, out, err = run_cli("--help")
    assert_equal 0, status
    assert_match(/Usage: forge-ci/, out)
    assert_match(/validate/, out)
    assert_match(/compile/, out)
    assert_match(/pipelines --project/, out)
    assert_match(/status <pipeline-id>/, out)
    assert_empty err
  end

  def test_help_short_flag
    status, out, _err = run_cli("-h")
    assert_equal 0, status
    assert_match(/Usage: forge-ci/, out)
  end

  def test_version_matches_gemspec
    status, out, err = run_cli("--version")
    assert_equal 0, status
    assert_equal ForgeCI::VERSION, out.strip
    assert_empty err
  end

  def test_unknown_command_exits_two
    status, _out, err = run_cli("frobnicate")
    assert_equal 2, status
    assert_match(/unknown command/, err)
  end

  def test_no_command_shows_help_and_exits_zero
    status, out, _err = run_cli
    assert_equal 0, status
    assert_match(/Usage: forge-ci/, out)
  end

  # -- validate --------------------------------------------------------------

  def test_validate_valid_config_exits_zero
    status, out, err = run_cli("validate", fixture_path("full.yml"))
    assert_equal 0, status
    assert_match(/valid/, out)
    assert_empty err
  end

  def test_validate_invalid_config_exits_one_with_line_numbers
    status, _out, err = run_cli("validate", fixture_path("invalid_cycle.yml"))
    assert_equal 1, status
    refute_empty err
    assert_match(/line \d+/, err)
    assert_match(/cycle/i, err)
  end

  def test_validate_missing_file_exits_one
    status, _out, err = run_cli("validate", fixture_path("does-not-exist.yml"))
    assert_equal 1, status
    assert_match(/no such file/, err)
  end

  def test_validate_missing_argument_exits_two
    status, _out, err = run_cli("validate")
    assert_equal 2, status
    assert_match(/requires a <config\.yml> argument/, err)
  end

  def test_validate_too_many_arguments_exits_two
    status, _out, err = run_cli("validate", fixture_path("full.yml"), "extra.yml")
    assert_equal 2, status
    assert_match(/exactly one/, err)
  end

  def test_validate_unparseable_yaml_exits_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.yml")
      File.write(path, "jobs:\n  - [\n")
      status, _out, err = run_cli("validate", path)
      assert_equal 1, status
      assert_match(/could not parse YAML/, err)
    end
  end

  def test_validate_command_help
    status, out, _err = run_cli("validate", "--help")
    assert_equal 0, status
    assert_match(/forge-ci validate <config\.yml>/, out)
  end

  def test_validate_bad_flag_exits_two
    status, _out, err = run_cli("validate", "--bogus")
    assert_equal 2, status
    assert_match(/invalid option/, err)
  end

  # -- compile ---------------------------------------------------------------

  def test_compile_pretty_json_by_default
    status, out, err = run_cli("compile", fixture_path("full.yml"))
    assert_equal 0, status
    assert_empty err
    assert_match(/\n/, out) # pretty-printed spans multiple lines
    parsed = JSON.parse(out)
    assert_equal "2.1", parsed["version"]
    assert parsed["workflows"].is_a?(Array)
  end

  def test_compile_compact_json_flag
    status, out, _err = run_cli("compile", fixture_path("full.yml"), "--json")
    assert_equal 0, status
    assert_equal 1, out.strip.lines.count # single line of JSON
    parsed = JSON.parse(out)
    assert_equal "2.1", parsed["version"]
  end

  def test_compile_with_branch_and_number_params
    status, out, _err = run_cli(
      "compile", fixture_path("interpolation.yml"),
      "--branch", "main", "--sha", "abc123", "--number", "42"
    )
    assert_equal 0, status
    parsed = JSON.parse(out)
    env = parsed["workflows"][0]["jobs"][0]["executor"]["environment"]
    assert_equal "hello", env["GREETING"]
    step = parsed["workflows"][0]["jobs"][0]["steps"].find { |s| s["name"] == "Greet" }
    assert_match(/from branch main \(build #42\)/, step["command"])
  end

  def test_compile_invalid_config_exits_one_with_errors
    status, _out, err = run_cli("compile", fixture_path("invalid_cycle.yml"))
    assert_equal 1, status
    refute_empty err
    assert_match(/line \d+/, err)
  end

  def test_compile_missing_file_exits_one
    status, _out, err = run_cli("compile", fixture_path("does-not-exist.yml"))
    assert_equal 1, status
    assert_match(/no such file/, err)
  end

  def test_compile_missing_argument_exits_two
    status, _out, err = run_cli("compile")
    assert_equal 2, status
    assert_match(/requires a <config\.yml> argument/, err)
  end

  def test_compile_command_help
    status, out, _err = run_cli("compile", "--help")
    assert_equal 0, status
    assert_match(/--branch/, out)
    assert_match(/--json/, out)
  end

  def test_compile_unparseable_yaml_exits_one
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.yml")
      File.write(path, "jobs:\n  - [\n")
      status, _out, err = run_cli("compile", path)
      assert_equal 1, status
      assert_match(/could not parse YAML/, err)
    end
  end

  # -- end-to-end through the exe wrapper -------------------------------------

  def test_exe_wrapper_is_executable
    exe = File.expand_path("../exe/forge-ci", __dir__)
    assert File.executable?(exe), "exe/forge-ci should be executable"
  end

  # -- trigger / cancel ------------------------------------------------------

  require "socket"

  # Tiny one-shot-per-request HTTP server recording requests.
  def with_fake_server(routes)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new do
      loop do
        sock = server.accept
        request_line = sock.gets.to_s
        headers = {}
        while (line = sock.gets) && line != "\r\n"
          k, v = line.split(": ", 2)
          headers[k.downcase] = v.to_s.strip
        end
        body = headers["content-length"] ? sock.read(headers["content-length"].to_i) : ""
        verb, path, = request_line.split
        requests << { verb: verb, path: path, headers: headers, body: body }
        response = routes.fetch("#{verb} #{path}") { [404, { error: "nope" }] }
        code, payload = response.respond_to?(:call) ? response.call(requests.last) : response
        json = JSON.generate(payload)
        sock.write "HTTP/1.1 #{code} X\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}"
        sock.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    server&.close
    thread&.kill
  end

  def test_trigger_compiles_and_posts_the_pipeline
    routes = { "POST /api/v1/projects/7/pipelines" => [201, { id: 42, status: "running" }] }
    with_fake_server(routes) do |url, requests|
      status, out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "7", "--url", url,
                                 "--token", "adm", "--branch", "main", "--sha", "deadbeef", "--context", "prod")
      assert_equal 0, status, err
      assert_match(/pipeline 42 started/, out)
      req = requests.first
      assert_equal "Bearer adm", req[:headers]["authorization"]
      body = JSON.parse(req[:body])
      assert_equal "deadbeef", body["sha"]
      assert_equal "main", body["branch"]
      assert_equal ["prod"], body["contexts"]
      assert body["ir"]["workflows"].any?
    end
  end

  def test_trigger_resolves_project_names_and_waits_for_success
    routes = {
      "GET /api/v1/projects" => [200, { projects: [{ id: 9, name: "demo" }] }],
      "POST /api/v1/projects/9/pipelines" => [201, { id: 5 }],
      "GET /api/v1/pipelines/5" => [200, { id: 5, status: "success" }]
    }
    with_fake_server(routes) do |url, _requests|
      status, out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "demo", "--url", url,
                                 "--token", "t", "--branch", "b", "--sha", "s", "--wait", "--poll", "0")
      assert_equal 0, status, err
      assert_match(/pipeline 5: success/, out)
    end
  end

  def test_trigger_wait_exits_one_when_pipeline_fails
    routes = {
      "POST /api/v1/projects/9/pipelines" => [201, { id: 5 }],
      "GET /api/v1/pipelines/5" => [200, { id: 5, status: "failed" }]
    }
    with_fake_server(routes) do |url, _requests|
      status, = run_cli("trigger", fixture_path("full.yml"), "--project", "9", "--url", url,
                        "--token", "t", "--branch", "b", "--sha", "s", "--wait", "--poll", "0")
      assert_equal 1, status
    end
  end

  def test_trigger_reports_server_errors
    routes = { "POST /api/v1/projects/9/pipelines" => [401, { error: "unauthorized" }] }
    with_fake_server(routes) do |url, _requests|
      status, _out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "9", "--url", url,
                                  "--token", "bad", "--branch", "b", "--sha", "s")
      assert_equal 1, status
      assert_match(/HTTP 401.*unauthorized/, err)
    end
  end

  def test_trigger_requires_project_url_and_token
    status, _out, err = run_cli("trigger", fixture_path("full.yml"), "--url", "http://x", "--token", "t")
    assert_equal 2, status
    assert_match(/--project/, err)
    status, _out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "1")
    assert_equal 2, status
    assert_match(/--url/, err)
  end

  def test_trigger_does_not_contact_server_for_an_invalid_config
    status, _out, err = run_cli("trigger", fixture_path("invalid_cycle.yml"), "--project", "1", "--url", "http://127.0.0.1:1",
                                "--token", "t", "--branch", "b", "--sha", "s")
    assert_equal 1, status
    refute_match(/could not reach/, err)
  end

  def test_cancel_posts_to_the_cancel_endpoint
    routes = { "POST /api/v1/pipelines/3/cancel" => [200, { id: 3, status: "canceled" }] }
    with_fake_server(routes) do |url, _requests|
      status, out, = run_cli("cancel", "3", "--url", url, "--token", "t")
      assert_equal 0, status
      assert_match(/canceled/, out)
    end
  end
  # -- pipelines / status ---------------------------------------------------

  def test_pipelines_resolves_names_and_encodes_filters_without_triggering
    branch = "feature/a & b?#"
    sha = "abc+def"
    query = URI.encode_www_form(branch: branch, sha: sha, limit: "3")
    payload = { pipelines: [{ id: 8, project_id: 9, status: "running", branch: branch, sha: sha }] }
    routes = {
      "GET /api/v1/projects" => [200, { projects: [{ id: 9, name: "demo" }] }],
      "GET /api/v1/projects/9/pipelines?#{query}" => [200, payload]
    }
    with_fake_server(routes) do |url, requests|
      status, out, err = run_cli("pipelines", "--project", "demo", "--branch", branch, "--sha", sha,
                                 "--limit", "3", "--json", "--url", url, "--token", "t")
      assert_equal 0, status, err
      assert_equal JSON.parse(JSON.generate(payload)), JSON.parse(out)
      assert_equal %w[GET GET], requests.map { |request| request[:verb] }
    end
  end

  def test_pipelines_table_and_empty_state
    payload = { pipelines: [{ id: 8, status: "failed", branch: "main", sha: "abc" }] }
    routes = { "GET /api/v1/projects/9/pipelines?limit=20" => [200, payload] }
    with_fake_server(routes) do |url, requests|
      status, out, err = run_cli("pipelines", "--project", "9", "--url", url, "--token", "t")
      assert_equal 0, status, err
      assert_includes out, "ID\tSTATUS\tBRANCH\tSHA"
      assert_includes out, "8\tfailed\tmain\tabc"
      payload[:pipelines].clear
      status, out, err = run_cli("pipelines", "--project", "9", "--url", url, "--token", "t")
      assert_equal 0, status, err
      assert_match(/no pipelines found/, out)
      assert requests.all? { |request| request[:verb] == "GET" }
    end
  end

  def pipeline_detail(status, job_status = status)
    { id: 5, project_id: 9, branch: "main", sha: "abc", status: status,
      workflows: [{ id: 10, name: "ci", status: status,
                    jobs: [{ id: 20, name: "test", node_index: 0, parallelism: 1,
                             status: job_status, requires: [] }] }] }
  end

  def test_status_reads_running_failed_and_canceled_without_failing_or_triggering
    %w[running failed canceled].each do |pipeline_status|
      payload = pipeline_detail(pipeline_status)
      with_fake_server("GET /api/v1/pipelines/5" => [200, payload]) do |url, requests|
        status, out, err = run_cli("status", "5", "--url", url, "--token", "t")
        assert_equal 0, status, err
        assert_includes out, "branch main sha abc"
        assert_includes out, "pipeline 5: #{pipeline_status}"
        assert_includes out, "workflow 10 (ci): #{pipeline_status}"
        assert_includes out, "job 20 (test[0]): #{pipeline_status}"
        assert_equal ["GET"], requests.map { |request| request[:verb] }
      end
    end
  end

  def test_status_wait_reports_job_transitions_while_pipeline_remains_running
    responses = [pipeline_detail("running", "pending"), pipeline_detail("running", "running"),
                 pipeline_detail("success")]
    routes = { "GET /api/v1/pipelines/5" => ->(_) { [200, responses.shift] } }
    with_fake_server(routes) do |url, requests|
      status, out, err = run_cli("status", "5", "--wait", "--poll", "0.001", "--url", url, "--token", "t")
      assert_equal 0, status, err
      assert_equal 1, out.scan("pipeline 5: running").length
      assert_match(/job 20 \(test\[0\]\): pending.*job 20 \(test\[0\]\): running.*job 20 \(test\[0\]\): success/m, out)
      assert_equal %w[GET GET GET], requests.map { |request| request[:verb] }
    end
  end

  def test_status_json_wait_emits_only_final_response_and_terminal_exit_code
    %w[success failed canceled].each do |terminal|
      final = pipeline_detail(terminal)
      responses = [pipeline_detail("running"), final]
      routes = { "GET /api/v1/pipelines/5" => ->(_) { [200, responses.shift] } }
      with_fake_server(routes) do |url, requests|
        status, out, err = run_cli("status", "5", "--wait", "--poll", "0.001", "--json", "--url", url, "--token", "t")
        assert_equal terminal == "success" ? 0 : 1, status, err
        assert_equal JSON.parse(JSON.generate(final)), JSON.parse(out)
        assert_equal 1, out.lines.length
        assert_equal %w[GET GET], requests.map { |request| request[:verb] }
      end
    end
  end

  def test_status_json_one_shot_includes_workflows_and_jobs
    payload = pipeline_detail("running")
    with_fake_server("GET /api/v1/pipelines/5" => [200, payload]) do |url, _requests|
      status, out, err = run_cli("status", "5", "--json", "--url", url, "--token", "t")
      assert_equal 0, status, err
      assert_equal JSON.parse(JSON.generate(payload)), JSON.parse(out)
    end
  end

  def test_pipeline_read_commands_report_http_and_watch_errors
    with_fake_server({}) do |url, _requests|
      [["pipelines", "--project", "9"], ["status", "5"]].each do |args|
        status, _out, err = run_cli(*args, "--url", url, "--token", "t")
        assert_equal 1, status
        assert_match(/HTTP 404/, err)
      end
    end
    responses = [[200, pipeline_detail("running")], [403, { error: "forbidden" }]]
    routes = { "GET /api/v1/pipelines/5" => ->(_) { responses.shift } }
    with_fake_server(routes) do |url, requests|
      status, out, err = run_cli("status", "5", "--wait", "--json", "--poll", "0.001", "--url", url, "--token", "t")
      assert_equal 1, status
      assert_empty out
      assert_match(/HTTP 403.*forbidden/, err)
      assert requests.all? { |request| request[:verb] == "GET" }
    end
  end

  def test_pipeline_read_commands_reject_invalid_arguments_before_network_access
    invalid = [["pipelines"], ["pipelines", "--project", "0"],
               ["pipelines", "--project", "9", "extra"], ["status"], ["status", "5", "extra"]]
    %w[0 -1 101 1.5 nope].each { |limit| invalid << ["pipelines", "--project", "9", "--limit", limit] }
    %w[0 -1 1.5 nope 5/other].each { |id| invalid << ["status", id] }
    %w[0 -1 NaN Infinity 1e309 nope].each { |poll| invalid << ["status", "5", "--poll", poll] }
    invalid.each do |args|
      status, _out, err = run_cli(*args, "--url", "http://127.0.0.1:1", "--token", "t")
      assert_equal 2, status, args.inspect
      refute_match(/could not reach/, err)
    end
  end

  def test_pipeline_read_commands_use_and_refresh_stored_oauth_sessions
    original = ENV["FORGE_CI_ADMIN_TOKEN"]
    ENV["FORGE_CI_ADMIN_TOKEN"] = nil
    [["pipelines", "--project", "9"], ["status", "5"]].each do |args|
      routes = {
        "POST /oauth/token" => [200, { access_token: "new-at", refresh_token: "new-rt", expires_in: 3600 }],
        "GET /api/v1/projects/9/pipelines?limit=20" => [200, { pipelines: [] }],
        "GET /api/v1/pipelines/5" => [200, pipeline_detail("running")]
      }
      with_fake_server(routes) do |url, requests|
        with_credentials_file do
          ForgeCI::Auth.write_server(url, "access_token" => "old", "refresh_token" => "refresh",
                                          "expires_at" => Time.now.to_i - 10)
          status, _out, err = run_cli(*args, "--url", url)
          assert_equal 0, status, err
          assert_equal "Bearer new-at", requests.last[:headers]["authorization"]
          status, _out, err = run_cli(*args, "--url", url)
          assert_equal 0, status, err
          assert_equal %w[POST GET GET], requests.map { |request| request[:verb] }
          status, _out, err = run_cli(*args, "--url", url, "--token", "explicit")
          assert_equal 0, status, err
          assert_equal "Bearer explicit", requests.last[:headers]["authorization"]
          refute requests.any? { |request| request[:verb] == "POST" && request[:path].include?("pipelines") }
        end
      end
    end
  ensure
    ENV["FORGE_CI_ADMIN_TOKEN"] = original
  end


  # -- skill -------------------------------------------------------------------

  def test_skill_show_prints_the_skill
    status, out, _err = run_cli("skill", "show")
    assert_equal 0, status
    assert_match(/\A---\nname: forge-ci\n/, out)
  end

  def test_skill_install_writes_and_refuses_to_overwrite
    Dir.mktmpdir do |dir|
      skills = File.join(dir, ".claude", "skills")
      status, out, = run_cli("skill", "install", "--dir", skills)
      assert_equal 0, status
      target = File.join(skills, "forge-ci", "SKILL.md")
      assert_equal File.read(ForgeCI::CLI::SKILL_SOURCE, encoding: "UTF-8"), File.read(target, encoding: "UTF-8")
      assert_match(/installed/, out)

      File.write(target, "my notes")
      status, _out, err = run_cli("skill", "install", "--dir", skills)
      assert_equal 1, status
      assert_match(/already exists/, err)
      assert_equal "my notes", File.read(target)

      assert_equal 0, run_cli("skill", "install", "--dir", skills, "--force").first
      refute_equal "my notes", File.read(target)
    end
  end

  def test_skill_without_subcommand_is_a_usage_error
    assert_equal 2, run_cli("skill").first
    assert_equal 2, run_cli("skill", "nope").first
  end

  # -- login / logout ------------------------------------------------------------

  def with_credentials_file
    Dir.mktmpdir do |dir|
      original = ENV["FORGE_CI_CREDENTIALS"]
      ENV["FORGE_CI_CREDENTIALS"] = File.join(dir, "credentials.json")
      yield
    ensure
      ENV["FORGE_CI_CREDENTIALS"] = original
    end
  end

  def run_cli_with_input(input, *args)
    out = StringIO.new
    err = StringIO.new
    status = ForgeCI::CLI.run(args, out: out, err: err, input: StringIO.new(input))
    [status, out.string, err.string]
  end

  def form_body(body)
    URI.decode_www_form(body.to_s).to_h
  end

  def test_login_manual_flow_stores_the_session
    routes = {
      "POST /oauth/token" => [200, { access_token: "at", refresh_token: "rt", token_type: "Bearer", expires_in: 3600 }],
      "GET /api/v1/me" => [200, { username: "alice", role: "admin" }]
    }
    with_fake_server(routes) do |url, requests|
      with_credentials_file do
        status, out, err = run_cli_with_input("thecode\n", "login", "--url", url, "--manual")
        assert_equal 0, status, err
        assert_match(%r{/oauth/authorize\?}, out)
        assert_match(/logged in as alice/, out)

        entry = ForgeCI::Auth.read_server(url)
        assert_equal "alice", entry["username"]
        assert_equal "at", entry["access_token"]
        assert_equal "rt", entry["refresh_token"]
        assert_includes (Time.now.to_i + 3600)..(Time.now.to_i + 3660), entry["expires_at"]

        form = form_body(requests.find { |r| r[:path] == "/oauth/token" }[:body])
        assert_equal "authorization_code", form["grant_type"]
        assert_equal "thecode", form["code"]
        assert_equal "forge-ci-cli", form["client_id"]
        assert_equal "urn:ietf:wg:oauth:2.0:oob", form["redirect_uri"]
        assert_match(/\A[A-Za-z0-9_-]{43,128}\z/, form["code_verifier"], "PKCE verifier travels")

        auth = requests.find { |r| r[:path] == "/api/v1/me" }[:headers]["authorization"]
        assert_equal "Bearer at", auth
      end
    end
  end

  def test_login_reports_server_side_oauth_errors
    routes = { "POST /oauth/token" => [400, { error: "invalid_grant", error_description: "bad code" }] }
    with_fake_server(routes) do |url, _requests|
      with_credentials_file do
        status, _out, err = run_cli_with_input("badcode\n", "login", "--url", url, "--manual")
        assert_equal 1, status
        assert_match(/bad code/, err)
        assert_nil ForgeCI::Auth.read_server(url)
      end
    end
  end

  def test_logout_revokes_and_forgets_the_session
    routes = { "POST /oauth/revoke" => [200, {}] }
    with_fake_server(routes) do |url, requests|
      with_credentials_file do
        ForgeCI::Auth.write_server(url, "username" => "alice", "access_token" => "at",
                                        "refresh_token" => "rt", "expires_at" => Time.now.to_i + 9999)

        status, out, = run_cli("logout", "--url", url)
        assert_equal 0, status
        assert_match(/logged out/, out)
        assert_nil ForgeCI::Auth.read_server(url)

        form = form_body(requests.first[:body])
        assert_equal "rt", form["token"]
        assert_equal "forge-ci-cli", form["client_id"]
      end
    end
  end

  def test_logout_without_a_session_is_fine
    with_fake_server({}) do |url, _requests|
      with_credentials_file do
        status, out, = run_cli("logout", "--url", url)
        assert_equal 0, status
        assert_match(/not logged in/, out)
      end
    end
  end

  def test_trigger_uses_the_stored_session_when_no_token_is_given
    routes = { "POST /api/v1/projects/7/pipelines" => [201, { id: 42, status: "running" }] }
    with_fake_server(routes) do |url, requests|
      with_credentials_file do
        ForgeCI::Auth.write_server(url, "access_token" => "stored", "expires_at" => Time.now.to_i + 9999)
        status, out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "7",
                                   "--url", url, "--branch", "b", "--sha", "s")
        assert_equal 0, status, err
        assert_equal "Bearer stored", requests.first[:headers]["authorization"]
      end
    end
  end

  def test_trigger_refreshes_an_expired_session_before_posting
    routes = {
      "POST /oauth/token" => [200, { access_token: "new-at", refresh_token: "new-rt", expires_in: 3600 }],
      "POST /api/v1/projects/7/pipelines" => [201, { id: 42, status: "running" }]
    }
    with_fake_server(routes) do |url, requests|
      with_credentials_file do
        ForgeCI::Auth.write_server(url, "access_token" => "old-at", "refresh_token" => "old-rt",
                                        "expires_at" => Time.now.to_i - 10)
        status, out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "7",
                                   "--url", url, "--branch", "b", "--sha", "s")
        assert_equal 0, status, err

        refresh = form_body(requests.find { |r| r[:path] == "/oauth/token" }[:body])
        assert_equal "refresh_token", refresh["grant_type"]
        assert_equal "old-rt", refresh["refresh_token"]
        assert_equal "Bearer new-at", requests.find { |r| r[:path].include?("/pipelines") }[:headers]["authorization"]

        entry = ForgeCI::Auth.read_server(url)
        assert_equal "new-at", entry["access_token"]
        assert_equal "new-rt", entry["refresh_token"]
      end
    end
  end

  def test_an_explicit_token_wins_over_the_stored_session
    routes = { "POST /api/v1/projects/7/pipelines" => [201, { id: 42 }] }
    with_fake_server(routes) do |url, requests|
      with_credentials_file do
        ForgeCI::Auth.write_server(url, "access_token" => "stored", "expires_at" => Time.now.to_i + 9999)
        status, = run_cli("trigger", fixture_path("full.yml"), "--project", "7",
                          "--url", url, "--token", "explicit", "--branch", "b", "--sha", "s")
        assert_equal 0, status
        assert_equal "Bearer explicit", requests.first[:headers]["authorization"]
      end
    end
  end

  def test_trigger_with_no_token_anywhere_points_at_login
    with_credentials_file do
      original = ENV["FORGE_CI_ADMIN_TOKEN"]
      ENV["FORGE_CI_ADMIN_TOKEN"] = nil
      status, _out, err = run_cli("trigger", fixture_path("full.yml"), "--project", "1",
                                  "--url", "http://127.0.0.1:1", "--branch", "b", "--sha", "s")
      assert_equal 2, status
      assert_match(/forge-ci login/, err)
    ensure
      ENV["FORGE_CI_ADMIN_TOKEN"] = original
    end
  end

  def test_login_rejects_out_of_range_callback_ports
    [-1, 65536].each do |port|
      status, _out, err = run_cli("login", "--url", "http://127.0.0.1:3000", "--port", port.to_s)
      assert_equal 2, status
      assert_match(/--port/, err)
    end
  end

  def test_login_requires_a_url
    original = ENV["FORGE_CI_URL"]
    ENV["FORGE_CI_URL"] = nil
    status, _out, err = run_cli("login")
    assert_equal 2, status
    assert_match(/--url/, err)
  ensure
    ENV["FORGE_CI_URL"] = original
  end
end
