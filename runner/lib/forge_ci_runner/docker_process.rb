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
        reader = Thread.new do
          Thread.current.report_on_exception = false
          loop do
            chunk = pipe.readpartial(16_384)
            chunk.force_encoding(Encoding.default_external)
            last_output = monotonic
            output << chunk if capture_output
            yield chunk if block_given?
          end
        rescue EOFError
          nil
        rescue IOError
          raise unless pipe.closed?
        end
        begin
          loop do
            now = monotonic
            reason = stop_check&.call
            reason ||= :job_timeout if deadline && now >= deadline
            reason ||= :no_output if no_output_timeout.to_f.positive? && now - last_output >= no_output_timeout
            break if reason

            if wait_thr.join(0)
              exited_at ||= now
              break if !reader.alive? || now - exited_at >= KILL_GRACE
            end
            reader.value if !reader.alive?
            sleep POLL_INTERVAL
          end
        ensure
          if reason || !wait_thr.join(0) || reader.alive?
            terminate(wait_thr)
          end
          pipe.close unless pipe.closed?
          reader.join(KILL_GRACE)
          reader.kill.join if reader.alive?
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
