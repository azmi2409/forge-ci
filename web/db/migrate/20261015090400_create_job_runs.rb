# frozen_string_literal: true

class CreateJobRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :job_runs do |t|
      t.references :workflow_run, null: false, foreign_key: true
      t.string :name, null: false
      # Full executor hash from the compiler IR (JSON, string keys).
      t.text :executor
      # IR step definitions (JSON array, string keys) — what the runner executes.
      t.text :steps
      t.string :working_directory
      # Pruned `requires` edges (job-name strings) from the compiler IR.
      t.text :requires
      # Denormalized executor.resource_class for indexed claim queries.
      t.string :resource_class
      # Merged environment from resolved contexts (JSON, values encrypted at rest
      # only via the Context records — this column holds the merged plain values
      # the runner needs; never render it in the UI).
      t.text :context_environment
      t.string :concurrency_key
      t.integer :status, null: false, default: 0
      t.string :claimed_by
      t.datetime :claimed_at
      t.datetime :heartbeat_at

      t.timestamps
    end

    add_index :job_runs, %i[workflow_run_id name], unique: true
    add_index :job_runs, :status
    add_index :job_runs, :resource_class
  end
end
