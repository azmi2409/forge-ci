# frozen_string_literal: true

class PartitionCachesByRunnerTrust < ActiveRecord::Migration[8.1]
  def change
    add_column :cache_entries, :fork_only, :boolean, null: false, default: false
    remove_index :cache_entries, %i[project_id key], unique: true
    add_index :cache_entries, %i[project_id key fork_only], unique: true
  end
end
