# frozen_string_literal: true

# ActiveRecord::Encryption keys for Context payloads.
#
# Production: the ACTIVE_RECORD_ENCRYPTION_* variables, or keys generated on
# first boot and kept on the data volume (see ForgeCISecrets). Back that volume
# up: without the keys, stored contexts can't be decrypted.
# Development/test: an insecure deterministic fallback so the app boots
# without configuration.
def forge_ci_encryption_key(name, label)
  key = ForgeCISecrets.fetch(name)
  return key if key.present?

  Rails.logger.warn "[forge-ci] #{ForgeCISecrets::SECRETS.fetch(name).first} not set — using INSECURE dev fallback key for #{label}"
  # Deterministic 32-byte key, hex-encoded like db:encryption:init output.
  Digest::SHA256.hexdigest("forge-ci-dev-fallback-#{label}-do-not-use-in-production")
end

Rails.application.config.active_record.encryption.primary_key =
  forge_ci_encryption_key("active_record_encryption_primary_key", "primary")
Rails.application.config.active_record.encryption.deterministic_key =
  forge_ci_encryption_key("active_record_encryption_deterministic_key", "deterministic")
Rails.application.config.active_record.encryption.key_derivation_salt =
  forge_ci_encryption_key("active_record_encryption_key_derivation_salt", "salt")
