# frozen_string_literal: true

module ForgeCIRunner
  # Buffers log output, redacts secrets, and POSTs seq-numbered chunks to
  # the control plane. The server upserts on (job_id, seq), so retries are
  # safe. Thread-safe: stdout/stderr reader threads share one instance.
  class LogStreamer
    # flush_interval: send buffered output at least this often (seconds), so
    # the job page shows it live instead of when chunk_size fills up.
    def initialize(client, job_id, redactor, chunk_size: 65_536, flush_interval: nil)
      @client = client
      @job_id = job_id
      @redactor = redactor
      @chunk_size = chunk_size
      @flush_interval = flush_interval
      @seq = 0
      @buffer = +""
      @mutex = Mutex.new
      @post_mutex = Mutex.new
      @flusher = nil
    end

    # Starts the background thread that sends partial chunks every
    # flush_interval. No-op without one. Stop it with #close.
    def start
      return self if @flusher || @flush_interval.to_f <= 0

      @stopping = false
      @flusher = Thread.new do
        loop do
          sleep @flush_interval
          break if @stopping

          flush
        end
      end
      self
    end

    # Stops the flusher (letting a POST in flight finish) and sends whatever
    # is left.
    def close
      if @flusher
        @stopping = true
        @flusher.wakeup if @flusher.alive? && @flusher.status == "sleep"
        @flusher.join
        @flusher = nil
      end
      flush
    end

    attr_reader :seq

    # Append raw output; flushes full chunks as they accumulate.
    def write(text)
      return if text.nil? || text.empty?

      pending = nil
      @mutex.synchronize do
        @buffer << @redactor.redact(text)
        pending = extract_chunks_locked
      end
      pending.each { |chunk| post_chunk(chunk) }
    end

    # POST any buffered remainder as a final chunk. Safe to call when empty.
    def flush
      pending = nil
      @mutex.synchronize { pending = extract_chunks_locked(force: true) }
      pending.each { |chunk| post_chunk(chunk) }
    end

    private

    # Splits whole chunks off the buffer. With force, emits the remainder
    # even when smaller than chunk_size.
    def extract_chunks_locked(force: false)
      chunks = []
      while @buffer.bytesize >= @chunk_size
        chunks << @buffer.byteslice(0, @chunk_size)
        @buffer = @buffer.byteslice(@chunk_size..-1) || +""
      end
      if force && !@buffer.empty?
        chunks << @buffer
        @buffer = +""
      end
      chunks
    end

    # One POST at a time, so chunks reach the server in seq order (the
    # flusher thread and the output readers both post).
    def post_chunk(chunk)
      @post_mutex.synchronize do
        seq = @mutex.synchronize { (@seq += 1) - 1 }
        with_retries { @client.post_log_chunk(@job_id, seq, chunk) }
      end
    end

    def with_retries(tries: 3)
      yield
    rescue StandardError => e
      tries -= 1
      if tries.positive?
        sleep 1
        retry
      end
      $stderr.puts "[forge-ci-runner] log chunk POST failed, dropping chunk: #{e.class}: #{e.message}"
    end
  end
end
