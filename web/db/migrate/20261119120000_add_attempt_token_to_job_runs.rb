# frozen_string_literal: true

class AddAttemptTokenToJobRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :job_runs, :attempt_token, :string
  end
end
