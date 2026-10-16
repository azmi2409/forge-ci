# frozen_string_literal: true

namespace :forge_ci do
  desc "Reclaim stale claimed/running jobs (no heartbeat within JobRun::STALE_HEARTBEAT_AFTER) back to queued"
  task reclaim: :environment do
    JobRun.reclaim_stale!
    puts "reclaim done"
  end
end

namespace :forge_ci do
  desc "Create or reset a UI user: FORGE_USERNAME=alice FORGE_PASSWORD=...  [FORGE_ROLE=admin|member]"
  task create_user: :environment do
    username = ENV["FORGE_USERNAME"].presence || abort("FORGE_USERNAME is required")
    password = ENV["FORGE_PASSWORD"].presence || abort("FORGE_PASSWORD is required")
    role = ENV.fetch("FORGE_ROLE", "admin")
    user = User.find_or_initialize_by(username: username)
    user.password = password
    user.role = role
    user.save!
    puts "#{user.previously_new_record? ? 'created' : 'updated'} #{role} #{user.username}"
  end
end
