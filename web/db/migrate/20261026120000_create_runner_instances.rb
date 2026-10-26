# frozen_string_literal: true

class CreateRunnerInstances < ActiveRecord::Migration[8.1]
  def change
    create_table :runner_instances do |t|
      t.references :runner_token, null: false, foreign_key: { on_delete: :cascade }
      t.string :uuid, null: false
      t.string :hostname, null: false, limit: 255
      t.string :implementation, null: false
      t.string :resource_class
      t.datetime :last_seen_at, null: false
      t.references :current_job_run, foreign_key: { to_table: :job_runs, on_delete: :nullify }
      t.timestamps
    end
    add_index :runner_instances, [:runner_token_id, :uuid], unique: true
  end
end
