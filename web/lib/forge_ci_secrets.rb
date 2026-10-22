# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "yaml"

# The control plane's secrets, so a production deploy needs no hand-made ones.
#
# Each secret comes from its environment variable when that is set. Otherwise,
# in production, it is generated once and kept in secrets.yml in the data
# directory (FORGE_CI_DATA_DIR, default web/storage, the volume that also holds
# uploaded files), readable only by the app's user. Back that directory up:
# losing the encryption keys makes stored contexts unreadable.
#
# Outside production nothing is generated or written; callers keep their
# development and test defaults.
module ForgeCISecrets
  # name => [environment variable, generator]
  SECRETS = {
    "secret_key_base" => ["SECRET_KEY_BASE", -> { SecureRandom.hex(64) }],
    "active_record_encryption_primary_key" => ["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", -> { SecureRandom.alphanumeric(32) }],
    "active_record_encryption_deterministic_key" => ["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", -> { SecureRandom.alphanumeric(32) }],
    "active_record_encryption_key_derivation_salt" => ["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", -> { SecureRandom.alphanumeric(32) }],
    "admin_token" => ["FORGE_CI_ADMIN_TOKEN", -> { SecureRandom.hex(32) }],
    "runner_token" => ["FORGE_CI_RUNNER_TOKEN", -> { SecureRandom.hex(32) }]
  }.freeze

  module_function

  # The secret's value: its environment variable, else (in production) the
  # generated one. nil outside production when the variable is unset.
  def fetch(name, env: ENV, generate: production?(env), dir: data_dir(env))
    variable, = SECRETS.fetch(name)
    value = env[variable].to_s.strip
    return value unless value.empty?
    return nil unless generate

    stored(dir).fetch(name)
  end

  def production?(env = ENV)
    mode = [env["RAILS_ENV"], env["RACK_ENV"]].map(&:to_s).find { |v| !v.empty? }
    mode == "production"
  end

  def data_dir(env = ENV)
    env["FORGE_CI_DATA_DIR"].to_s.strip.empty? ? File.expand_path("../storage", __dir__) : env["FORGE_CI_DATA_DIR"]
  end

  # Loads secrets.yml, generating any missing secret. A lock file keeps two
  # processes booting at once from generating different values.
  def stored(dir)
    @stored ||= {}
    @stored[dir] ||= begin
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "secrets.yml")
      File.open(File.join(dir, ".secrets.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
        missing = SECRETS.keys - current.keys
        unless missing.empty?
          missing.each { |name| current[name] = SECRETS.fetch(name).last.call }
          write_private(path, current.to_yaml)
        end
        current
      end
    end
  end

  # Writes the runner token in use to runner-token in the data directory, for
  # runners that share the volume (the compose runner reads RUNNER_TOKEN_FILE).
  def publish_runner_token!(env: ENV, dir: data_dir(env))
    token = fetch("runner_token", env: env, dir: dir)
    return if token.nil?

    path = File.join(dir, "runner-token")
    return if File.exist?(path) && File.read(path).strip == token

    FileUtils.mkdir_p(dir)
    write_private(path, "#{token}\n")
  end

  def write_private(path, content)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(content) }
    File.rename(tmp, path)
  end

  # Tests only.
  def reset!
    @stored = nil
  end
end
