# frozen_string_literal: true

# `parallelism: N` runs N copies (nodes) of one job; each is its own JobRun
# sharing the job's name, told apart by node_index (CIRCLE_NODE_INDEX).
class AddParallelismToJobRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :job_runs, :parallelism, :integer, null: false, default: 1
    add_column :job_runs, :node_index, :integer, null: false, default: 0

    remove_index :job_runs, %i[workflow_run_id name], unique: true
    add_index :job_runs, %i[workflow_run_id name node_index], unique: true
  end
end
