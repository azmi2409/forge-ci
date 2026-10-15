# frozen_string_literal: true

# A named cache tarball scoped to a project, backed by an ActiveStorage
# file (component 7). Lookup follows CircleCI semantics: for each requested
# key in order, exact match wins; otherwise the most recently created entry
# whose key starts with the requested key (prefix fallback).
class CacheEntry < ApplicationRecord
  belongs_to :project

  has_one_attached :file

  validates :key, presence: true, uniqueness: { scope: :project_id }

  # Find the best entry for the requested keys (tried in order): exact match
  # first, then longest-prefix fallback per key. Returns nil on total miss.
  def self.lookup(project, keys)
    Array(keys).map(&:to_s).each do |key|
      next if key.blank?

      exact = project.cache_entries.find_by(key: key)
      return exact if exact

      prefixed = project.cache_entries
                        .where("key LIKE ?", "#{sanitize_sql_like(key)}%")
                        .order(created_at: :desc)
                        .first
      return prefixed if prefixed
    end
    nil
  end
end
