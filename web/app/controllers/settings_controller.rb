# frozen_string_literal: true

# Admin settings: connect GitHub, add runners, the admin API token.
class SettingsController < ApplicationController
  before_action :require_admin

  def show
    @base_url = control_plane_url
    @github = Github.stored
    @github_from_env = Github.from_env?
    @runner_token = ForgeCISecrets.fetch("runner_token")
    @admin_token = ForgeCISecrets.fetch("admin_token")
    @queue = JobRun.where(status: %w[queued claimed running]).group(:resource_class).count
    @public_url = !URI.parse(@base_url).host.to_s.match?(/\A(localhost|127\.|0\.0\.0\.0|\[::1\])/)
  end

  # Starts "Connect GitHub": renders a form that posts the manifest to GitHub.
  def github
    @state = session[:github_manifest_state] = SecureRandom.hex(16)
    @manifest = Github::Manifest.build(control_plane_url)
    @action = Github::Manifest.new_app_url(org: params[:org].to_s.strip.presence, state: @state)
    render :github_redirect, layout: false
  end

  # GitHub sends the user back here with a one-time code for the new App.
  def github_callback
    expected = session.delete(:github_manifest_state)
    if expected.blank? || !ActiveSupport::SecurityUtils.secure_compare(expected, params[:state].to_s)
      return redirect_to settings_path, alert: "GitHub connection expired or didn't match. Try Connect GitHub again."
    end

    credential = GithubAppCredential.create_from_manifest_conversion!(Github::Manifest.convert(params[:code].to_s))
    redirect_to credential.install_url, allow_other_host: true
  rescue Github::AppClient::ApiError, KeyError, JSON::ParserError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.warn("[github] manifest conversion failed: #{e.class}: #{e.message}")
    redirect_to settings_path, alert: "GitHub didn't finish creating the App (#{e.class.name.demodulize}). Try Connect GitHub again."
  end

  private

  def control_plane_url
    (Github.app_host.presence || request.base_url).sub(%r{/+\z}, "")
  end
end
