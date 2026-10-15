# frozen_string_literal: true

class CreateStepRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :step_runs do |t|
      t.references :job_run, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :status, null: false, default: 0
      t.integer :exit_code
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :step_runs, %i[job_run_id name], unique: true
  end
end
