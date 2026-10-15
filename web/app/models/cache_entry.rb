# frozen_string_literal: true

# Record of a cache entry a job saved via save_cache. v1 stores the record
# only — storage backend and the runner upload/download API are deferred
# (see README "not yet").
class CacheEntry < ApplicationRecord
  belongs_to :project

  validates :key, presence: true, uniqueness: { scope: :project_id }
end
