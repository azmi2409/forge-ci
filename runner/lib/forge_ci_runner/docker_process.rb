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
        watcher = Thread.new do
          Thread.current.report_on_exception = false
          completed = false
          begin
            until wait_thr.join(POLL_INTERVAL)
              now = monotonic
              reason = stop_check&.call
              reason ||= :job_timeout if deadline && now >= deadline
              reason ||= :no_output if no_output_timeout.to_f.positive? && now - last_output >= no_output_timeout
              break if reason
            end
            completed = true
          ensure
            if reason || !completed
              terminate(wait_thr)
              reader.join(KILL_GRACE) if completed
              reader.kill.join if reader.alive?
            end
          end
        end
        begin
          reader.value
          status = wait_thr.value
        ensure
          begin
            terminate(wait_thr) unless wait_thr.join(0)
            watcher.value
          ensure
            reader.kill.join if reader.alive?
            pipe.close unless pipe.closed?
          end
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
