# frozen_string_literal: true

# ActiveRecord::Encryption keys for Context payloads.
#
# Production: set all three env vars (generate with `bin/rails db:encryption:init`).
# Development/test: an insecure deterministic fallback is derived so the app
# boots without configuration. NEVER use the fallback in production.
def forge_ci_encryption_key(env_name, label)
  key = ENV[env_name]
  return key if key.present?

  if Rails.env.production?
    raise "Missing #{env_name} — generate keys with `bin/rails db:encryption:init` and export them"
  end

  Rails.logger.warn "[forge-ci] #{env_name} not set — using INSECURE dev fallback key for #{label}"
  # Deterministic 32-byte key, hex-encoded like db:encryption:init output.
  Digest::SHA256.hexdigest("forge-ci-dev-fallback-#{label}-do-not-use-in-production")
end

Rails.application.config.active_record.encryption.primary_key =
  forge_ci_encryption_key("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", "primary")
Rails.application.config.active_record.encryption.deterministic_key =
  forge_ci_encryption_key("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", "deterministic")
Rails.application.config.active_record.encryption.key_derivation_salt =
  forge_ci_encryption_key("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "salt")
