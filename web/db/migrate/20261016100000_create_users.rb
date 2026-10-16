# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :username, null: false
      t.string :password_digest, null: false
      t.integer :role, null: false, default: 0
      # Rotated on password change / "sign out everywhere"; every session
      # cookie carries a copy, so rotating it invalidates all other sessions.
      t.string :session_nonce, null: false
      t.integer :failed_attempts, null: false, default: 0
      t.datetime :locked_until
      t.datetime :last_login_at

      t.timestamps
    end

    add_index :users, :username, unique: true
  end
end
