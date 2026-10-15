# frozen_string_literal: true

class CreateRunnerTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :runner_tokens do |t|
      t.string :name, null: false
      # SHA256 hex digest ONLY — the raw token is shown once at generation
      # and never stored.
      t.string :token_digest, null: false
      t.string :resource_class

      t.timestamps
    end

    add_index :runner_tokens, :name, unique: true
    add_index :runner_tokens, :token_digest, unique: true
  end
end
