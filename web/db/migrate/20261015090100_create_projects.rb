# frozen_string_literal: true

class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :repo_url
      t.string :default_branch, null: false, default: "main"
      t.integer :max_concurrency, null: false, default: 4

      t.timestamps
    end
  end
end
