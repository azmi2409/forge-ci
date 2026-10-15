# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class TarballTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("tarball-test")
    FileUtils.mkdir_p(File.join(@dir, "src", "sub"))
    File.write(File.join(@dir, "src", "a.txt"), "hello")
    File.write(File.join(@dir, "src", "sub", "b.txt"), "world")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_create_and_extract_round_trip
    tgz = File.join(@dir, "out.tgz")
    ForgeCIRunner::Tarball.create(["a.txt", "sub"],
                                  base_dir: File.join(@dir, "src"), dest: tgz)
    dest = File.join(@dir, "dest")
    ForgeCIRunner::Tarball.extract(tgz, dest_dir: dest)
    assert_equal "hello", File.read(File.join(dest, "a.txt"))
    assert_equal "world", File.read(File.join(dest, "sub", "b.txt"))
  end

  def test_create_skips_missing_paths_with_warning
    warnings = []
    tgz = File.join(@dir, "out.tgz")
    ForgeCIRunner::Tarball.create(["a.txt", "missing.txt"],
                                  base_dir: File.join(@dir, "src"), dest: tgz,
                                  warn: ->(m) { warnings << m })
    assert_equal 1, warnings.length
    assert_match(/missing\.txt/, warnings.first)
    assert File.file?(tgz)
  end

  def test_create_raises_when_nothing_exists
    err = assert_raises(ForgeCIRunner::Tarball::Error) do
      ForgeCIRunner::Tarball.create(["nope"],
                                    base_dir: File.join(@dir, "src"),
                                    dest: File.join(@dir, "out.tgz"))
    end
    assert_match(/nothing to archive/, err.message)
  end

  def test_extract_creates_dest_dir
    tgz = File.join(@dir, "out.tgz")
    ForgeCIRunner::Tarball.create(["a.txt"],
                                  base_dir: File.join(@dir, "src"), dest: tgz)
    dest = File.join(@dir, "new", "nested")
    ForgeCIRunner::Tarball.extract(tgz, dest_dir: dest)
    assert_equal "hello", File.read(File.join(dest, "a.txt"))
  end
end
