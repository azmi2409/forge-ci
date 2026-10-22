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

namespace :forge_ci do
  desc "First boot: create the first admin if there are no users (prints a generated password once)"
  task bootstrap: :environment do
    user, generated = User.bootstrap_admin_from_env!
    next unless user

    puts "forge-ci: created the first admin user '#{user.username}'"
    if generated
      puts "forge-ci:   password: #{generated}"
      puts "forge-ci:   (also saved to #{User.initial_password_path}; change it under Account after signing in)"
    end
  end
end

namespace :forge_ci do
  desc "Give the first admin a new random password and print it (creates 'admin' if there is none)"
  task reset_admin: :environment do
    user, password = User.reset_admin_password!
    puts "forge-ci: admin user '#{user.username}'"
    puts "forge-ci:   password: #{password}"
    puts "forge-ci:   change it under Account after signing in"
  end
end
