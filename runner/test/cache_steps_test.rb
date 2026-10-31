# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# Fake runner-facing client with an in-memory cache/artifact store, so
# cache and workspace steps can be tested round-trip without HTTP.
class FakeRunnerClient
  attr_reader :calls

  def initialize
    @calls = []
    @cache = {} # key => bytes
  end

  def post_log_chunk(*); end

  def put_cache(project_id, key, tarball_path)
    @calls << [:put_cache, project_id, key]
    @cache[key] = File.binread(tarball_path)
    { "key" => key, "size" => @cache[key].bytesize }
  end

  def get_cache(project_id, keys)
    @calls << [:get_cache, project_id, keys]
    hit = Array(keys).find { |k| @cache.key?(k) }
    return nil if hit.nil?

    { "key" => hit, "size" => @cache[hit].bytesize,
      "download_url" => "fakestore://#{hit}" }
  end

  def download(url, dest)
    @calls << [:download, url]
    key = url.sub(%r{\Afakestore://}, "")
    raise "no such cached key #{key}" unless @cache.key?(key)

    File.binwrite(dest, @cache[key])
    dest
  end

  def post_artifact(job_id, local_path, path:, destination: nil)
    @calls << [:post_artifact, job_id, path, destination]
    { "id" => @calls.length, "path" => path, "size" => File.size(local_path) }
  end
end

# RecordingExecutor with container file ops stubbed to local fixtures.
class CacheRecordingExecutor < RecordingExecutor
  attr_accessor :fixture_tgz, :sha256_map

  def fetch_tarball(_container_tgz, host_dir = nil)
    @commands << [:fetch_tarball]
    host_dir ||= Dir.mktmpdir("forge-ci-fetch")
    dest = File.join(host_dir, "fixture.tgz")
    FileUtils.cp(@fixture_tgz, dest)
    dest
  end

  def send_tarball(_host_tgz)
    @commands << [:send_tarball]
    "/tmp/fake-restore.tgz"
  end

  def container_sha256(rel)
    @commands << [:sha256, rel]
    @sha256_map && @sha256_map[rel]
  end
end

class CacheStepsTest < Minitest::Test
  def cache_payload(overrides = {})
    test_payload({
      "project_id" => 3,
      "workflow_run_id" => 42,
      "repository" => { "url" => "https://github.com/acme/demo.git",
                        "sha" => "abc123", "branch" => "main" }
    }.merge(overrides))
  end

  def runner(payload_overrides = {}, config_overrides = {})
    client = FakeRunnerClient.new
    ex = CacheRecordingExecutor.new(test_config(config_overrides), client,
                                    cache_payload(payload_overrides))
    [ex, client]
  end

  # Builds a real tarball on the host to stand in for container output.
  def fixture_tgz(files)
    dir = Dir.mktmpdir("cache-steps-fixture")
    src = File.join(dir, "src")
    FileUtils.mkdir_p(src)
    files.each do |rel, content|
      full = File.join(src, rel)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
    tgz = File.join(dir, "fixture.tgz")
    ForgeCIRunner::Tarball.create(files.keys, base_dir: src, dest: tgz)
    [tgz, dir]
  end

  def test_checkout_prefers_payload_repository_url
    ex, _ = runner({ "steps" => [{ "type" => "checkout" }] },
                   { checkout_repo_url: "https://fallback.example/r.git" })
    ex.execute
    cmd = ex.commands.find { |c| c[0] == :stream_exec }
    refute_nil cmd
    joined = cmd[1].join(" ")
    assert_includes joined, "https://github.com/acme/demo.git"
    refute_includes joined, "fallback.example"
  end

  def test_checkout_falls_back_to_env_url
    payload = cache_payload("steps" => [{ "type" => "checkout" }])
    payload.delete("repository")
    ex = CacheRecordingExecutor.new(test_config(checkout_repo_url: "https://fallback.example/r.git"),
                                    FakeRunnerClient.new, payload)
    ex.execute
    cmd = ex.commands.find { |c| c[0] == :stream_exec }
    refute_nil cmd
    assert_includes cmd[1].join(" "), "https://fallback.example/r.git"
  end

  def test_save_cache_skips_only_exact_existing_key
    ["gems-v1", "gems-v1-newer", nil, :error].each do |existing|
      tgz, dir = fixture_tgz("vendor/a.txt" => "v")
      begin
        ex, client = runner("steps" => [{ "type" => "save_cache", "keys" => ["gems-v1"], "paths" => ["vendor"] }])
        ex.fixture_tgz = tgz
        client.define_singleton_method(:get_cache) do |*|
          raise "lookup unavailable" if existing == :error
          existing && { "key" => existing, "download_url" => "unused" }
        end
        status, = ex.execute
        assert_equal "success", status
        should_upload = existing.nil? || existing == "gems-v1-newer"
        assert_equal should_upload, client.calls.any? { |c| c[0] == :put_cache }, existing.inspect
        assert_equal should_upload, ex.commands.any? { |c| c[0] == :fetch_tarball }, existing.inspect
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  def test_save_cache_resolves_key_and_uploads
    tgz, dir = fixture_tgz("vendor/a.txt" => "v")
    begin
      ex, client = runner(
        "steps" => [{ "type" => "save_cache",
                      "keys" => ['v1-{{ checksum "Gemfile.lock" }}-{{ .Branch }}'],
                      "paths" => ["vendor"] }]
      )
      ex.fixture_tgz = tgz
      ex.sha256_map = { "Gemfile.lock" => "deadbeef" }

      status, _ = ex.execute

      assert_equal "success", status
      put = client.calls.find { |c| c[0] == :put_cache }
      refute_nil put
      assert_equal 3, put[1]
      assert_equal "v1-deadbeef-main", put[2]
      # tar ran inside the container against the workdir
      tar_cmd = ex.commands.find { |c| c[0] == :run_docker && c[1].include?("tar") }
      refute_nil tar_cmd
      assert_includes tar_cmd[1], "-czf"
      assert_includes tar_cmd[1], "vendor"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_save_cache_checksum_missing_file_uses_empty_string
    tgz, dir = fixture_tgz("vendor/a.txt" => "v")
    begin
      ex, client = runner(
        "steps" => [{ "type" => "save_cache",
                      "keys" => ['v1-{{ checksum "nope.txt" }}'],
                      "paths" => ["vendor"] }]
      )
      ex.fixture_tgz = tgz
      ex.sha256_map = {}

      status, _ = ex.execute

      assert_equal "success", status
      put = client.calls.find { |c| c[0] == :put_cache }
      assert_equal "v1-", put[2]
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_restore_cache_hit_extracts_into_workdir
    tgz, dir = fixture_tgz("vendor/a.txt" => "v")
    begin
      client = FakeRunnerClient.new
      client.put_cache(3, "k1", tgz) # seed the fake store
      ex = CacheRecordingExecutor.new(test_config, client,
                                      cache_payload(
                                        "steps" => [{ "type" => "restore_cache",
                                                      "keys" => %w[k1 k2] }]))

      status, _ = ex.execute

      assert_equal "success", status
      get = client.calls.find { |c| c[0] == :get_cache }
      assert_equal [%w[k1 k2]], [get[2]]
      extract = ex.commands.find { |c| c[0] == :run_docker && c[1].include?("tar") }
      refute_nil extract
      assert_includes extract[1], "-xzf"
      assert_includes extract[1], "/root/project"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_restore_cache_miss_does_not_fail
    ex, client = runner("steps" => [{ "type" => "restore_cache",
                                      "keys" => ["nope"] }])
    status, results = ex.execute
    assert_equal "success", status
    assert_equal 0, results.first["exit_code"]
    assert client.calls.any? { |c| c[0] == :get_cache }
  end

  def test_store_artifacts_uploads_each_file
    tgz, dir = fixture_tgz("coverage/index.html" => "<html>",
                           "coverage/app.js" => "js")
    begin
      ex, client = runner(
        "steps" => [{ "type" => "store_artifacts",
                      "path" => "coverage", "destination" => "reports" }]
      )
      ex.fixture_tgz = tgz

      status, _ = ex.execute

      assert_equal "success", status
      posts = client.calls.select { |c| c[0] == :post_artifact }
      assert_equal 2, posts.length
      paths = posts.map { |c| c[2] }.sort
      assert_equal %w[coverage/app.js coverage/index.html], paths
      assert posts.all? { |c| c[3] == "reports" }
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_workspace_persist_then_attach_round_trip
    tgz, dir = fixture_tgz("dist/app.js" => "js")
    begin
      client = FakeRunnerClient.new
      persist = CacheRecordingExecutor.new(
        test_config, client,
        cache_payload("steps" => [{ "type" => "persist_to_workspace",
                                    "root" => ".", "paths" => ["dist"] }])
      )
      persist.fixture_tgz = tgz
      status, _ = persist.execute
      assert_equal "success", status

      put_keys = client.calls.select { |c| c[0] == :put_cache }.map { |c| c[2] }
      assert_includes put_keys, "forge-ci-workspace/42/root.tgz"
      assert_includes put_keys, "forge-ci-workspace/42/manifest.json"

      attach = CacheRecordingExecutor.new(
        test_config, client,
        cache_payload("steps" => [{ "type" => "attach_workspace", "at" => "www" }])
      )
      status, _ = attach.execute
      assert_equal "success", status

      extract = attach.commands.find { |c| c[0] == :run_docker && c[1].include?("tar") }
      refute_nil extract
      assert_includes extract[1], "/root/project/www"
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  def test_attach_workspace_empty_workspace_is_noop
    ex, _ = runner("steps" => [{ "type" => "attach_workspace", "at" => "www" }])
    status, results = ex.execute
    assert_equal "success", status
    assert_equal 0, results.first["exit_code"]
  end
end
