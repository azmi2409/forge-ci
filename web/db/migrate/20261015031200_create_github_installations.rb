# frozen_string_literal: true

# GitHub App installations of the forge-ci app (component 3).
# Rows are created/removed by the `installation` webhook event.
class CreateGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_installations do |t|
      t.bigint :installation_id, null: false
      t.string :account_login, null: false
      t.string :account_type, null: false, default: "Organization"

      t.timestamps
    end
    add_index :github_installations, :installation_id, unique: true

    create_table :github_repositories do |t|
      t.references :github_installation, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :full_name, null: false

      t.timestamps
    end
    add_index :github_repositories, :full_name, unique: true

    change_table :pipelines do |t|
      t.boolean :forked, null: false, default: false
      t.integer :pipeline_number
      t.references :github_repository, foreign_key: true
    end
    add_index :pipelines, %i[project_id pipeline_number], unique: true
  end
end
