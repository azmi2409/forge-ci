# frozen_string_literal: true

require "open3"

module ForgeCIRunner
  class DockerProcess
    KILL_GRACE = 5
    POLL_INTERVAL = 0.05

    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.capture(argv, deadline: nil, stop_check: nil, no_output_timeout: nil, capture_output: true)
      output = +""
      reason = stop_check&.call
      reason ||= :job_timeout if deadline && monotonic >= deadline
      return [output, nil, reason] if reason

      status = nil
      Open3.popen2e(*argv, pgroup: true) do |stdin, pipe, wait_thr|
        stdin.close
        last_output = monotonic
        exited_at = nil
        eof = false
        begin
          loop do
            now = monotonic
            reason = stop_check&.call
            reason ||= :job_timeout if deadline && now >= deadline
            reason ||= :no_output if no_output_timeout.to_f.positive? && now - last_output >= no_output_timeout
            break if reason

            if wait_thr.join(0)
              exited_at ||= now
              break if eof || now - exited_at >= KILL_GRACE
            end
            if eof
              wait_thr.join(POLL_INTERVAL)
              next
            end
            next unless IO.select([pipe], nil, nil, POLL_INTERVAL)

            chunk = pipe.read_nonblock(16_384, exception: false)
            if chunk.nil?
              eof = true
            elsif chunk != :wait_readable
              chunk.force_encoding(Encoding.default_external)
              last_output = monotonic
              output << chunk if capture_output
              yield chunk if block_given?
            end
          end
        ensure
          if reason || !wait_thr.join(0) || !eof
            terminate(wait_thr)
          end
          pipe.close unless pipe.closed?
          status = wait_thr.value
        end
      end
      [output, status, reason]
    end

    def self.terminate(wait_thr)
      begin
        Process.kill("TERM", -wait_thr.pid)
        wait_thr.join(KILL_GRACE)
      rescue Errno::ESRCH
        nil
      ensure
        begin
          Process.kill("KILL", -wait_thr.pid)
        rescue Errno::ESRCH
          nil
        end
        wait_thr.join
      end
    end
  end
end
