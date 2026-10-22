# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

# Runs the `circleci` helper the runner installs into job containers.
class CircleciCliTest < Minitest::Test
  CLI = File.expand_path("../lib/forge_ci_runner/circleci_cli.sh", __dir__)

  def setup
    skip "bash is not available" unless system("bash", "-c", "true")
    @dir = Dir.mktmpdir
    # Files of different sizes, in nested directories.
    { "test/a_test.rb" => 900, "test/models/b_test.rb" => 100, "test/models/c_test.rb" => 500,
      "test/deep/x/d_test.rb" => 300, "test/e_test.rb" => 700, "test/helper.rb" => 50 }.each do |path, size|
      FileUtils.mkdir_p(File.join(@dir, File.dirname(path)))
      File.write(File.join(@dir, path), "x" * size)
    end
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def cli(*args, stdin: "", env: {})
    out, err, status = Open3.capture3(env, "bash", CLI, *args, stdin_data: stdin, chdir: @dir)
    [out, err, status.exitstatus]
  end

  def all_tests
    cli("tests", "glob", "test/**/*_test.rb").first
  end

  def test_glob_matches_nested_files_only
    assert_equal %w[test/a_test.rb test/deep/x/d_test.rb test/e_test.rb test/models/b_test.rb test/models/c_test.rb],
                 all_tests.split
  end

  def test_every_split_covers_each_file_exactly_once
    files = all_tests.split
    %w[name filesize timings].each do |mode|
      shares = (0...3).map do |i|
        cli("tests", "split", "--split-by=#{mode}", stdin: all_tests,
                                                    env: { "CIRCLE_NODE_TOTAL" => "3", "CIRCLE_NODE_INDEX" => i.to_s }).first.split
      end
      assert_equal files.sort, shares.flatten.sort, "#{mode}: union must be every file once"
      assert shares.all?(&:any?), "#{mode}: every node gets files"
    end
  end

  def test_filesize_balances_bytes
    shares = (0...2).map do |i|
      cli("tests", "split", "--split-by=filesize", stdin: all_tests,
                                                   env: { "CIRCLE_NODE_TOTAL" => "2", "CIRCLE_NODE_INDEX" => i.to_s }).first.split
    end
    bytes = shares.map { |files| files.sum { |f| File.size(File.join(@dir, f)) } }
    assert_equal [1300, 1200], bytes # 900+300+100 vs 700+500
  end

  def test_timings_warns_and_falls_back
    _out, err, code = cli("tests", "split", "--split-by=timings", stdin: all_tests)
    assert_equal 0, code
    assert_match(/falls? back|filesize/, err)
  end

  def test_run_pipes_this_nodes_share_to_the_command
    out, _err, code = cli("tests", "run", "--command=xargs echo ran", stdin: all_tests,
                                                                        env: { "CIRCLE_NODE_TOTAL" => "2", "CIRCLE_NODE_INDEX" => "0" })
    assert_equal 0, code
    assert_match(/\Aran test\//, out)
  end

  def test_run_skips_the_command_when_the_share_is_empty
    out, err, code = cli("tests", "run", "--command=echo SHOULD-NOT-RUN", stdin: "only_test.rb",
                                                                          env: { "CIRCLE_NODE_TOTAL" => "2", "CIRCLE_NODE_INDEX" => "1" })
    assert_equal 0, code
    refute_match(/SHOULD-NOT-RUN/, out)
    assert_match(/no tests for node 1/, err)
  end

  def test_run_propagates_a_failing_command
    _out, _err, code = cli("tests", "run", "--command=xargs false", stdin: all_tests)
    refute_equal 0, code
  end

  def test_rejects_bad_input
    assert_equal 2, cli("tests", "split", env: { "CIRCLE_NODE_TOTAL" => "2", "CIRCLE_NODE_INDEX" => "2" }).last
    assert_equal 2, cli("tests", "split", "--split-by=random").last
    assert_equal 2, cli("tests", "run").last
    assert_equal 2, cli("config", "validate").last
  end
end
