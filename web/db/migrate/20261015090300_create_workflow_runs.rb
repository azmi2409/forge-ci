# frozen_string_literal: true

class CreateWorkflowRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :workflow_runs do |t|
      t.references :pipeline, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :status, null: false, default: 0

      t.timestamps
    end

    add_index :workflow_runs, %i[pipeline_id name], unique: true
  end
end
