# frozen_string_literal: true

# Record of an artifact a job declared via store_artifacts, backed by an
# ActiveStorage file (component 7). Downloads go through
# Api::V1::ArtifactsController#download, which redirects to a fresh
# time-limited signed URL — the blob key itself is never exposed as a
# permanent address.
class Artifact < ApplicationRecord
  belongs_to :job_run

  has_one_attached :file

  validates :path, presence: true

  # How long uploaded artifacts are kept. Old ones are purged by
  # PurgeOldArtifactsJob (see config/recurring.yml).
  def self.retention_period
    (ENV.fetch("ARTIFACT_RETENTION_DAYS", "30").to_i.clamp(1, 3650)).days
  end

  def purge_file!
    file.purge if file.attached?
  end
end
