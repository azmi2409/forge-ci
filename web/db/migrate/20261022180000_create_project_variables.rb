# frozen_string_literal: true

# Project environment variables, set in the dashboard and given to every job
# of the project's pipelines (never to fork pull requests). Values are
# encrypted with ActiveRecord::Encryption.
class CreateProjectVariables < ActiveRecord::Migration[8.1]
  def change
    create_table :project_variables do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      t.text :value, null: false
      t.timestamps
    end
    add_index :project_variables, %i[project_id name], unique: true
  end
end
