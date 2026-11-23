# frozen_string_literal: true

class CreateGithubCommitStatuses < ActiveRecord::Migration[8.1]
  def change
    create_table :github_commit_statuses do |t|
      t.references :pipeline, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :state, null: false
      t.string :description, null: false
      t.integer :generation, null: false, default: 1
      t.datetime :delivered_at
      t.string :last_error
      t.timestamps
    end
  end
end
