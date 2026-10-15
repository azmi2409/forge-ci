# frozen_string_literal: true

class CreateCacheEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :cache_entries do |t|
      t.references :project, null: false, foreign_key: true
      t.string :key, null: false
      t.string :storage_key
      t.bigint :size

      t.timestamps
    end

    add_index :cache_entries, %i[project_id key], unique: true
  end
end
