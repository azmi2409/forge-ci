# frozen_string_literal: true

# A named set of secret environment variables scoped to a project.
#
# Values are encrypted at rest via ActiveRecord::Encryption (see
# config/initializers/encryption.rb). The raw payload is NEVER rendered in
# views, API responses, or logs — runners receive only the merged plain
# environment on the claim response (see JobRun#merged_environment).
class Context < ApplicationRecord
  belongs_to :project

  validates :name, presence: true, uniqueness: { scope: :project_id }

  encrypts :encrypted_payload

  # Hash of ENV name -> value. Stored as JSON inside the encrypted column.
  def payload
    raw = encrypted_payload
    raw.present? ? JSON.parse(raw) : {}
  end

  def payload=(hash)
    self.encrypted_payload = hash.present? ? JSON.dump(hash) : nil
  end

  # Never leak secret values via inspect.
  def inspect
    "#<#{self.class.name} id: #{id}, project_id: #{project_id}, name: #{name.inspect}, payload: [FILTERED]>"
  end
end
