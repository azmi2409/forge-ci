# frozen_string_literal: true

# The GitHub App created from the Settings page ("Connect GitHub", GitHub's
# app-manifest flow). GITHUB_APP_ID / GITHUB_APP_PRIVATE_KEY /
# GITHUB_WEBHOOK_SECRET in the environment still take precedence.
class CreateGithubAppCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :github_app_credentials do |t|
      t.string :app_id, null: false
      t.string :slug, null: false
      t.string :name
      t.string :html_url
      t.string :owner_login
      t.string :client_id
      t.text :client_secret
      t.text :webhook_secret, null: false
      t.text :private_key, null: false
      t.timestamps
    end
  end
end
