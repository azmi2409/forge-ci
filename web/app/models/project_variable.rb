# frozen_string_literal: true

# An environment variable set on a project in the dashboard. Every job of the
# project's pipelines gets it, except jobs of fork pull requests. It is read
# when a runner claims the job (JobRun#merged_environment), so a change applies
# to jobs that haven't started yet and the value is never copied elsewhere.
#
# The value is encrypted at rest and never shown again after it is saved; the
# dashboard shows only its last characters.
class ProjectVariable < ApplicationRecord
  NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  MAX_VALUE_BYTES = 64 * 1024

  belongs_to :project

  encrypts :value

  validates :name, presence: true, length: { maximum: 255 }, uniqueness: { scope: :project_id }
  validates :name, format: { with: NAME, message: "must start with a letter or _ and contain only letters, digits and _" },
                   allow_blank: true
  validates :value, presence: true
  validate :value_size

  # "••••a1b2" for long values, "••••" for short ones (which would give most of
  # the secret away).
  def masked_value
    v = value.to_s
    v.length >= 12 ? "••••#{v[-4..]}" : "••••"
  end

  def inspect
    "#<#{self.class.name} id: #{id}, project_id: #{project_id}, name: #{name.inspect}, value: [FILTERED]>"
  end

  private

  def value_size
    errors.add(:value, "is too long (64 KB at most)") if value.to_s.bytesize > MAX_VALUE_BYTES
  end
end
