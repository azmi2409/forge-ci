# frozen_string_literal: true

class AddRefreshTokenEnabledToOauthApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_applications, :refresh_token_enabled, :boolean, default: true, null: false
  end
end
