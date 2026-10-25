# frozen_string_literal: true

# Authentication credential for Docker runners. Only the SHA256 hex digest is
# stored — the raw token is shown once at generation time and never again.
#
# Most deployments use one shared secret instead (Drone-style): any runner
# presenting it authenticates as the "static-runner" token, auto-provisioned
# on first use. It is FORGE_CI_RUNNER_TOKEN when set, otherwise (production)
# the token generated on first boot, which the Runners page shows in the
# install command.
class RunnerToken < ApplicationRecord
  STATIC_TOKEN_NAME = "static-runner"

  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true
  validates :name, exclusion: { in: [STATIC_TOKEN_NAME] }, if: :fork_only?

  # Create a token; returns [record, raw_token]. Print/store the raw token
  # now — it cannot be recovered later.
  def self.generate!(name:, resource_class: nil, fork_only: false)
    raw = SecureRandom.hex(32)
    record = create!(
      name: name,
      token_digest: Digest::SHA256.hexdigest(raw),
      resource_class: resource_class,
      fork_only: fork_only
    )
    [record, raw]
  end

  # Returns the token record for a valid raw bearer token, else nil.
  # Digest comparison is constant-time.
  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    presented = raw_token.to_s.strip

    # Operator-provisioned static secret (compose/Coolify). Auto-provisions a
    # real record on first use so job ownership (claimed_by) works uniformly.
    # resource_class is nil, so the token may claim jobs of any class.
    static_secret = ForgeCISecrets.fetch("runner_token").to_s
    if static_secret.present? &&
       ActiveSupport::SecurityUtils.secure_compare(presented, static_secret)
      return static_token_record!(static_secret)
    end

    digest = Digest::SHA256.hexdigest(presented)
    record = find_by(token_digest: digest)
    return nil unless record

    ActiveSupport::SecurityUtils.secure_compare(record.token_digest, digest) ? record : nil
  end
  private_class_method def self.static_token_record!(static_secret)
    find_or_create_by!(name: STATIC_TOKEN_NAME) do |t|
      t.token_digest = Digest::SHA256.hexdigest(static_secret)
      t.resource_class = nil
    end
  rescue ActiveRecord::RecordNotUnique
    # Lost a race with another process provisioning the same record.
    find_by!(name: STATIC_TOKEN_NAME)
  end

  def inspect
    "#<#{self.class.name} id: #{id}, name: #{name.inspect}, resource_class: #{resource_class.inspect}, token_digest: [FILTERED]>"
  end
end
