# frozen_string_literal: true

# Authentication credential for Docker runners. Only the SHA256 hex digest is
# stored — the raw token is shown once at generation time and never again.
class RunnerToken < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :token_digest, presence: true, uniqueness: true

  # Create a token; returns [record, raw_token]. Print/store the raw token
  # now — it cannot be recovered later.
  def self.generate!(name:, resource_class: nil)
    raw = SecureRandom.hex(32)
    record = create!(
      name: name,
      token_digest: Digest::SHA256.hexdigest(raw),
      resource_class: resource_class
    )
    [record, raw]
  end

  # Returns the token record for a valid raw bearer token, else nil.
  # Digest comparison is constant-time.
  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    digest = Digest::SHA256.hexdigest(raw_token.to_s.strip)
    record = find_by(token_digest: digest)
    return nil unless record

    ActiveSupport::SecurityUtils.secure_compare(record.token_digest, digest) ? record : nil
  end

  def inspect
    "#<#{self.class.name} id: #{id}, name: #{name.inspect}, resource_class: #{resource_class.inspect}, token_digest: [FILTERED]>"
  end
end
