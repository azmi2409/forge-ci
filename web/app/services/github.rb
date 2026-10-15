# frozen_string_literal: true

# Namespace for the GitHub App integration (component 3).
#
# Configuration comes from the environment (see README "GitHub App setup"):
#   GITHUB_APP_ID            numeric App ID
#   GITHUB_APP_PRIVATE_KEY   the App's private key, PEM text
#   GITHUB_WEBHOOK_SECRET    webhook HMAC secret (fail-closed: required)
#   APP_HOST                 public base URL, e.g. https://ci.example.com
module Github
  CONFIG_MISSING_MESSAGE =
    "GitHub App not configured — set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY"

  def self.app_id
    ENV["GITHUB_APP_ID"].presence
  end

  def self.private_key_pem
    ENV["GITHUB_APP_PRIVATE_KEY"].presence
  end

  def self.webhook_secret
    ENV["GITHUB_WEBHOOK_SECRET"].presence
  end

  def self.app_host
    ENV["APP_HOST"].presence
  end

  def self.configured?
    app_id.present? && private_key_pem.present?
  end

  # Factory seam — tests override Github.client_factory to avoid real
  # network calls. Production always gets a real AppClient.
  class << self
    attr_writer :client_factory

    def client_factory
      @client_factory ||= ->(id) { AppClient.new(installation_id: id) }
    end
  end

  def self.client_for(installation_id)
    client_factory.call(installation_id)
  end
end
