# frozen_string_literal: true

class CreateContexts < ActiveRecord::Migration[8.1]
  def change
    create_table :contexts do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      # Encrypted JSON object of ENV name -> value (see Context#payload).
      # NEVER rendered in views or API responses; never logged.
      t.text :encrypted_payload

      t.timestamps
    end

    add_index :contexts, %i[project_id name], unique: true
  end
end
