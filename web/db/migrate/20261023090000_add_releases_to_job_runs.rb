# frozen_string_literal: true

# How often a runner handed this job back to the queue on shutdown
# (REQUEUE_ON_SHUTDOWN); capped at JobRun::MAX_RELEASES.
class AddReleasesToJobRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :job_runs, :releases, :integer, null: false, default: 0
  end
end
