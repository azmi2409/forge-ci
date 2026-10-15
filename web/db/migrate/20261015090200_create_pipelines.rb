# frozen_string_literal: true

class CreatePipelines < ActiveRecord::Migration[8.1]
  def change
    create_table :pipelines do |t|
      t.references :project, null: false, foreign_key: true
      t.string :sha, null: false
      t.string :branch, null: false
      t.integer :status, null: false, default: 0

      t.timestamps
    end

    add_index :pipelines, %i[project_id created_at]
  end
end
