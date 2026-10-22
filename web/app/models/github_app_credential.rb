# frozen_string_literal: true

# A GitHub App created through "Connect GitHub" on the Settings page. The
# newest row is the one in use; secrets are encrypted at rest.
class GithubAppCredential < ApplicationRecord
  encrypts :client_secret, :webhook_secret, :private_key

  validates :app_id, :slug, :webhook_secret, :private_key, presence: true

  def self.current
    order(:id).last
  end

  # From GitHub's POST /app-manifests/{code}/conversions response.
  def self.create_from_manifest_conversion!(data)
    create!(
      app_id: data.fetch("id").to_s,
      slug: data.fetch("slug"),
      name: data["name"],
      html_url: data["html_url"],
      owner_login: data.dig("owner", "login"),
      client_id: data["client_id"],
      client_secret: data["client_secret"],
      webhook_secret: data.fetch("webhook_secret"),
      private_key: data.fetch("pem")
    )
  end

  def install_url
    "https://github.com/apps/#{slug}/installations/new"
  end
end
