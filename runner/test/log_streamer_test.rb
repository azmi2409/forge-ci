# frozen_string_literal: true

require "test_helper"

class FakeLogClient
  attr_reader :chunks

  def initialize(failures_before_success: 0)
    @chunks = []
    @mutex = Mutex.new
    @failures_left = failures_before_success
  end

  def post_log_chunk(job_id, seq, chunk)
    if @failures_left.positive?
      @failures_left -= 1
      raise IOError, "boom"
    end

    @mutex.synchronize { @chunks << [job_id, seq, chunk] }
  end
end

class LogStreamerTest < Minitest::Test
  def streamer(client, chunk_size: 10)
    redactor = ForgeCIRunner::Redactor.new({ "K" => "long-secret-value" })
    ForgeCIRunner::LogStreamer.new(client, 42, redactor, chunk_size: chunk_size)
  end

  def test_buffers_until_chunk_size_then_posts_with_seq
    client = FakeLogClient.new
    s = streamer(client, chunk_size: 10)
    s.write("12345")
    assert_empty client.chunks
    s.write("67890") # buffer now exactly 10 -> one chunk
    assert_equal [[42, 0, "1234567890"]], client.chunks
    assert_equal 1, s.seq
  end

  def test_flush_posts_remainder
    client = FakeLogClient.new
    s = streamer(client, chunk_size: 100)
    s.write("partial")
    s.flush
    assert_equal [[42, 0, "partial"]], client.chunks
    s.flush # idempotent when empty
    assert_equal 1, client.chunks.length
  end

  def test_redaction_applied_before_post
    client = FakeLogClient.new
    s = streamer(client, chunk_size: 100)
    s.write("leaked long-secret-value here")
    s.flush
    assert_equal "leaked [REDACTED] here", client.chunks.first[2]
  end

  def test_retries_then_drops_chunk_without_raising
    client = FakeLogClient.new(failures_before_success: 100)
    s = streamer(client, chunk_size: 100)
    # must not raise even though every POST fails
    s.write("lost log line")
    s.flush
    assert_empty client.chunks
  end

  def test_recovers_after_transient_failures
    client = FakeLogClient.new(failures_before_success: 2)
    s = streamer(client, chunk_size: 100)
    s.write("eventually posted")
    s.flush
    assert_equal [[42, 0, "eventually posted"]], client.chunks
  end

  def test_thread_safe_writes
    client = FakeLogClient.new
    s = streamer(client, chunk_size: 7)
    threads = 4.times.map do |i|
      Thread.new { 25.times { s.write("t#{i}line\n") } }
    end
    threads.each(&:join)
    s.flush
    seqs = client.chunks.map { |c| c[1] }
    assert_equal seqs.sort, seqs # monotonically increasing
    assert_equal seqs.uniq.length, seqs.length # no duplicates
    total = client.chunks.map { |c| c[2] }.join
    assert_equal 4 * 25, total.scan(/t\dline/).length
  end
end
