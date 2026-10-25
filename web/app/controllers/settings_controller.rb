# frozen_string_literal: true

# Admin settings: connect GitHub, add runners, the admin API token.
class SettingsController < ApplicationController
  before_action :require_admin

  GITHUB_LOGIN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/

  def show
    @base_url = control_plane_url
    @github = Github.stored
    @github_from_env = Github.from_env?
    @runner_token = ForgeCISecrets.fetch("runner_token")
    @admin_token = ForgeCISecrets.fetch("admin_token")
    @queue = JobRun.where(status: %w[queued claimed running]).group(:resource_class).count
    @fork_runner_tokens = RunnerToken.where(fork_only: true).order(:name)
    @public_url = !URI.parse(@base_url).host.to_s.match?(/\A(localhost|127\.|0\.0\.0\.0|\[::1\])/)
  end

  def create_fork_runner
    _record, @fork_runner_secret = RunnerToken.generate!(
      name: params[:name].to_s.strip,
      resource_class: params[:resource_class].to_s.strip.presence,
      fork_only: true
    )
    show
    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy_fork_runner
    RunnerToken.where(fork_only: true).find(params[:id]).destroy!
    redirect_to settings_path, notice: "Fork runner token revoked. Destroy its host; do not reuse it for trusted jobs."
  end

  # Starts "Connect GitHub": renders a form that posts the manifest to GitHub.
  # A private App can only be installed on the account that owns it, so the
  # admin picks that account: an organization (by name) or their own.
  def github
    org = params[:account] == "personal" ? nil : params[:org].to_s.strip.delete_prefix("@").presence
    if params[:account] == "org" && org.nil?
      return redirect_to settings_path, alert: "Enter the name of the organization that owns your repositories."
    end
    if org && !org.match?(GITHUB_LOGIN)
      return redirect_to settings_path, alert: "\"#{org.truncate(40)}\" isn't a GitHub organization name."
    end

    @state = session[:github_manifest_state] = SecureRandom.hex(16)
    @manifest = Github::Manifest.build(control_plane_url)
    @action = Github::Manifest.new_app_url(org: org, state: @state)
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
