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
end
