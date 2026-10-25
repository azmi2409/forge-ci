# frozen_string_literal: true

class AddForkOnlyToRunnerTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :runner_tokens, :fork_only, :boolean, default: false, null: false
  end
end
