# frozen_string_literal: true

# Returns stale claimed/running jobs (no heartbeat within
# JobRun::STALE_HEARTBEAT_AFTER) to the queue so another runner can pick them
# up. Scheduled every JobRun::RECLAIM_INTERVAL via config/recurring.yml
# (Solid Queue) — or run on a cron with `bin/rails forge_ci:reclaim`.
class ReclaimStaleJobsJob < ApplicationJob
  queue_as :default

  def perform
    JobRun.reclaim_stale!
  end
end
