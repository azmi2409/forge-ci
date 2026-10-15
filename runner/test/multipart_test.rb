# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class MultipartTest < Minitest::Test
  def test_body_streams_fields_and_file_with_correct_size
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.tgz")
      File.binwrite(path, "TARBALL-BYTES" * 10_000) # ~130KB: spans read chunks
      body = ForgeCIRunner::Multipart::Body.new(
        { "key" => "bundle-v1" },
        [{ name: "file", filename: "c.tgz", path: path }]
      )

      assert_match(%r{\Amultipart/form-data; boundary=}, body.content_type)

      streamed = +"".b
      while (chunk = body.read(8192))
        streamed << chunk
      end

      assert_equal body.size, streamed.bytesize
      assert_includes streamed, 'name="key"'
      assert_includes streamed, "bundle-v1"
      assert_includes streamed, 'filename="c.tgz"'
      assert_includes streamed, ("TARBALL-BYTES" * 10_000).b
      assert streamed.end_with?("--\r\n".b)
    end
  end

  def test_read_returns_nil_at_eof_and_reset_replays
    body = ForgeCIRunner::Multipart::Body.new({ "a" => "b" }, [])
    first = body.read(1_000_000)
    refute_nil first
    assert_nil body.read(1_000_000)

    body.reset
    second = body.read(1_000_000)
    assert_equal first, second
  end

  def test_multiple_files
    Dir.mktmpdir do |dir|
      p1 = File.join(dir, "one.txt")
      p2 = File.join(dir, "two.txt")
      File.write(p1, "one")
      File.write(p2, "two")
      body = ForgeCIRunner::Multipart::Body.new(
        {},
        [{ name: "f1", path: p1 }, { name: "f2", path: p2 }]
      )
      streamed = +"".b
      while (chunk = body.read(4096))
        streamed << chunk
      end
      assert_equal body.size, streamed.bytesize
      assert_includes streamed, 'filename="one.txt"'
      assert_includes streamed, 'filename="two.txt"'
    end
  end
end
