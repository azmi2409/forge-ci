# frozen_string_literal: true

# Namespace for the GitHub App integration (component 3).
#
# The App is normally created with "Connect GitHub" on the Settings page
# (GithubAppCredential). These environment variables take precedence:
#   GITHUB_APP_ID            numeric App ID
#   GITHUB_APP_PRIVATE_KEY   the App's private key, PEM text
#   GITHUB_WEBHOOK_SECRET    webhook HMAC secret (fail-closed: required)
#   APP_HOST                 public base URL, e.g. https://ci.example.com
module Github
  CONFIG_MISSING_MESSAGE =
    "GitHub App not configured — use Connect GitHub on the Settings page, or set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY"

  def self.app_id
    ENV["GITHUB_APP_ID"].presence || stored&.app_id
  end

  def self.private_key_pem
    # .env files / PaaS dashboards often store the PEM on one line with
    # literal "\n" sequences — restore the real newlines.
    ENV["GITHUB_APP_PRIVATE_KEY"].presence&.gsub("\\n", "\n") || stored&.private_key
  end

  def self.webhook_secret
    ENV["GITHUB_WEBHOOK_SECRET"].presence || stored&.webhook_secret
  end

  # The App created from the Settings page, if any.
  def self.stored
    GithubAppCredential.current
  rescue ActiveRecord::ActiveRecordError
    nil
  end

  # True when the App comes from the environment rather than the Settings page.
  def self.from_env?
    ENV["GITHUB_APP_ID"].present?
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
