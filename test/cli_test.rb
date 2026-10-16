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
        code, payload = routes.fetch("#{verb} #{path}") { [404, { error: "nope" }] }
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
end
