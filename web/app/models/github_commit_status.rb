# frozen_string_literal: true

# The commit status GitHub should show for a pipeline, kept until it has been
# delivered (see Github::StatusPoster). One row per pipeline, because
# forge-ci posts a single context: a newer state replaces an undelivered
# older one, so a retried delivery always sends the latest state and never
# puts "pending" back over a finished build.
class GithubCommitStatus < ApplicationRecord
  belongs_to :pipeline

  # Record the state GitHub should show and return the row. Each call bumps
  # the generation, so a delivery already posting an older state cannot mark
  # this one delivered.
  def self.record!(pipeline, state:, description:)
    now = Time.current
    upsert(
      { pipeline_id: pipeline.id, state: state, description: description, created_at: now, updated_at: now },
      unique_by: :pipeline_id,
      on_duplicate: Arel.sql(<<~SQL.squish)
        state = excluded.state, description = excluded.description,
        generation = github_commit_statuses.generation + 1,
        delivered_at = NULL, last_error = NULL, updated_at = excluded.updated_at
      SQL
    )
    find_by!(pipeline_id: pipeline.id)
  end

  # Record the pipeline's first state, unless a state is already recorded:
  # a pipeline can finish before its initial "pending" is recorded, and that
  # pending must not replace the result.
  def self.record_initial!(pipeline, state:, description:)
    now = Time.current
    insert(
      { pipeline_id: pipeline.id, state: state, description: description, created_at: now, updated_at: now },
      unique_by: :pipeline_id
    )
    find_by!(pipeline_id: pipeline.id)
  end

  def delivered?
    delivered_at.present?
  end

  # Both return false, changing nothing, when a newer state was recorded
  # since `generation` was read.
  def mark_delivered!(generation)
    update_if_current(generation, delivered_at: Time.current, last_error: nil)
  end

  def mark_failed!(generation, error)
    update_if_current(generation, last_error: "#{error.class}: #{error.message}".truncate(255))
  end

  private

  def update_if_current(generation, attributes)
    self.class.where(id: id, generation: generation)
        .update_all(attributes.merge(updated_at: Time.current)) == 1
  end
end
