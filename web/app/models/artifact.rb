# frozen_string_literal: true

# Record of an artifact a job declared via store_artifacts. v1 stores the
# record only — upload to object storage and the upload API are deferred
# (see README "not yet").
class Artifact < ApplicationRecord
  belongs_to :job_run

  validates :path, presence: true
end
