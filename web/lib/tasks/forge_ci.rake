# frozen_string_literal: true

namespace :forge_ci do
  desc "Reclaim stale claimed/running jobs (no heartbeat within JobRun::STALE_HEARTBEAT_AFTER) back to queued"
  task reclaim: :environment do
    JobRun.reclaim_stale!
    puts "reclaim done"
  end
end
