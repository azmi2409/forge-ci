# frozen_string_literal: true

class AddJobClaimIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEXES = [%i[status created_at id], %i[workflow_run_id status]].freeze

  def up
    INDEXES.each do |columns|
      next if index_exists?(:job_runs, columns, valid: true)

      # An interrupted concurrent build can leave an invalid index behind.
      remove_index :job_runs, columns, **index_options if index_exists?(:job_runs, columns)
      add_index :job_runs, columns, **index_options
    end
  end

  def down
    INDEXES.reverse_each { |columns| remove_index :job_runs, columns, if_exists: true, **index_options }
  end

  private

  def index_options
    connection.adapter_name == "PostgreSQL" ? { algorithm: :concurrently } : {}
  end
end
