# frozen_string_literal: true

# Deletes artifacts older than Artifact.retention_period (ARTIFACT_RETENTION_DAYS,
# default 30 days), purging the ActiveStorage file first so blobs don't leak
# in storage. Scheduled daily via config/recurring.yml (Solid Queue).
class PurgeOldArtifactsJob < ApplicationJob
  queue_as :default

  def perform
    cutoff = Artifact.retention_period.ago
    Artifact.where("created_at < ?", cutoff).find_each do |artifact|
      artifact.purge_file!
      artifact.destroy!
    end
  end
end
