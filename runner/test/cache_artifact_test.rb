# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class CacheArtifactClientTest < Minitest::Test
  def setup
    @server = FakeControlPlane.new
    @client = ForgeCIRunner::Client.new(runner_config_for(@server))
    @dir = Dir.mktmpdir("cache-artifact-test")
  end

  def teardown
    @server.close
    FileUtils.rm_rf(@dir)
  end

  def test_put_cache_sends_multipart_with_key_and_file
    tgz = File.join(@dir, "c.tgz")
    File.binwrite(tgz, "fake-tgz-bytes")
    @server.stub("PUT", "/api/v1/projects/3/cache", "200",
                 { "key" => "k1", "size" => 14 })

    result = @client.put_cache(3, "k1", tgz)

    assert_equal({ "key" => "k1", "size" => 14 }, result)
    req = @server.last_request
    assert_equal "PUT", req[:method]
    assert_match(%r{\Amultipart/form-data; boundary=}, req[:headers]["content-type"])
    body = req[:body]
    assert_includes body, 'name="key"'
    assert_includes body, "k1"
    assert_includes body, 'name="file"; filename="c.tgz"'
    assert_includes body, "fake-tgz-bytes"
    assert_equal "Bearer test-token", req[:headers]["authorization"]
  end

  def test_get_cache_returns_hit
    @server.stub("GET", "/api/v1/projects/3/cache?keys%5B%5D=k1&keys%5B%5D=k2", "200",
                 { "key" => "k1", "size" => 14,
                   "download_url" => "http://127.0.0.1:#{@server.port}/dl/c.tgz" })
    hit = @client.get_cache(3, %w[k1 k2])
    assert_equal "k1", hit["key"]
    assert_match(%r{/dl/c\.tgz}, hit["download_url"])
  end

  def test_get_cache_returns_nil_on_404
    @server.stub("GET", "/api/v1/projects/3/cache?keys%5B%5D=missing", "404",
                 { "error" => "no matching cache entry" })
    assert_nil @client.get_cache(3, ["missing"])
  end

  def test_get_cache_raises_on_403
    @server.stub("GET", "/api/v1/projects/3/cache?keys%5B%5D=k", "403",
                 { "error" => "forbidden" })
    assert_raises(ForgeCIRunner::Client::HTTPError) { @client.get_cache(3, ["k"]) }
  end

  def test_download_writes_binary_body_to_file
    @server.stub_raw("GET", "/dl/c.tgz", "200", "application/gzip", "BINARY-BYTES")

    dest = File.join(@dir, "out.tgz")
    @client.download("http://127.0.0.1:#{@server.port}/dl/c.tgz", dest)
    assert_equal "BINARY-BYTES", File.binread(dest)
  end

  def test_download_follows_redirect
    target = "/dl/c.tgz"
    @server.stub_redirect("GET", "/redir",
                          "http://127.0.0.1:#{@server.port}#{target}")
    @server.stub_raw("GET", target, "200", "application/gzip", "REDIRECTED-BYTES")

    dest = File.join(@dir, "out.tgz")
    @client.download("http://127.0.0.1:#{@server.port}/redir", dest)
    assert_equal "REDIRECTED-BYTES", File.binread(dest)
  end

  def test_download_raises_on_404
    @server.stub_raw("GET", "/nope", "404", "application/json", "{}")
    err = assert_raises(ForgeCIRunner::Client::HTTPError) do
      @client.download("http://127.0.0.1:#{@server.port}/nope", File.join(@dir, "o"))
    end
    assert_equal "404", err.code
  end

  def test_post_artifact_sends_file_path_and_destination
    f = File.join(@dir, "index.html")
    File.write(f, "<html>")
    @server.stub("POST", "/api/v1/jobs/9/artifacts", "201",
                 { "id" => 7, "path" => "coverage/index.html",
                   "destination" => "reports", "size" => 6 })

    result = @client.post_artifact(9, f, path: "coverage/index.html",
                                   destination: "reports")

    assert_equal 7, result["id"]
    body = @server.last_request[:body]
    assert_includes body, 'name="path"'
    assert_includes body, "coverage/index.html"
    assert_includes body, 'name="destination"'
    assert_includes body, "reports"
    assert_includes body, "<html>"
  end

  def test_cache_store_save_and_restore_round_trip
    store = ForgeCIRunner::CacheStore.new(@client, 3)
    tgz = File.join(@dir, "c.tgz")
    File.binwrite(tgz, "tgz-data")
    @server.stub("PUT", "/api/v1/projects/3/cache", "200",
                 { "key" => "k", "size" => 8 })
    saved = store.save("k", tgz)
    assert_equal "k", saved["key"]

    @server.stub("GET", "/api/v1/projects/3/cache?keys%5B%5D=k", "200",
                 { "key" => "k", "size" => 8,
                   "download_url" => "http://127.0.0.1:#{@server.port}/dl/k.tgz" })
    @server.stub_raw("GET", "/dl/k.tgz", "200", "application/gzip", "tgz-data")
    local = store.restore(["k"])
    refute_nil local
    assert_equal "tgz-data", File.binread(local)
    FileUtils.rm_rf(File.dirname(local))
  end

  def test_cache_store_restore_miss_returns_nil
    store = ForgeCIRunner::CacheStore.new(@client, 3)
    @server.stub("GET", "/api/v1/projects/3/cache?keys%5B%5D=nope", "404",
                 { "error" => "no matching cache entry" })
    assert_nil store.restore(["nope"])
    assert_nil store.restore([])
  end

  def test_cache_store_save_rejects_bad_args
    store = ForgeCIRunner::CacheStore.new(@client, 3)
    assert_raises(ArgumentError) { store.save("", File.join(@dir, "x")) }
    assert_raises(ArgumentError) { store.save("k", File.join(@dir, "missing")) }
  end

  def test_artifact_store_upload
    store = ForgeCIRunner::ArtifactStore.new(@client, 9)
    f = File.join(@dir, "a.txt")
    File.write(f, "data")
    @server.stub("POST", "/api/v1/jobs/9/artifacts", "201",
                 { "id" => 1, "size" => 4 })
    result = store.upload(f, path: "a.txt")
    assert_equal 1, result["id"]
    assert_raises(ArgumentError) { store.upload(File.join(@dir, "missing")) }
  end
end
