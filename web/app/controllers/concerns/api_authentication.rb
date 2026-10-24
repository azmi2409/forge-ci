# frozen_string_literal: true

# Bearer-token auth for the JSON API. Two kinds of credentials are accepted:
#
# * the shared admin token (FORGE_CI_ADMIN_TOKEN, or in production the token
#   generated on first boot and shown on the Settings page) — full access,
#   meant for scripts and CI;
# * an OAuth access token issued by `forge-ci login` (Doorkeeper) — the
#   request acts as the signed-in user, so endpoints guarded with
#   require_admin! answer 403 for members.
#
# Deliberately separate from runner tokens: runners must never be able to
# start pipelines or read/rewrite secrets. Fails closed: without a valid
# credential every request answers 401.
module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_api!
  end

  private

  # The User an OAuth token acts as; nil for the shared admin token.
  attr_reader :current_api_user

  # Whether the request authenticated with the shared admin token rather
  # than a user's OAuth token.
  def admin_token?
    @admin_token == true
  end

  def authenticate_api!
    provided = bearer_credentials
    if admin_token_matches?(provided)
      @admin_token = true
      return
    end

    if provided.present?
      token = Doorkeeper::AccessToken.by_token(provided)
      if token&.accessible? && token.scopes.exists?("api")
        @current_api_user = User.find_by(id: token.resource_owner_id)
        return if current_api_user
      end
    end

    error = { error: "unauthorized: valid bearer token required" }
    error[:hint] = "set FORGE_CI_ADMIN_TOKEN or run forge-ci login" unless admin_token_configured?
    render json: error, status: :unauthorized
  end

  # Installations-affecting endpoints (start pipelines, create projects,
  # rotate secrets, autoscaler queue depth): the admin token or an admin
  # user's OAuth token.
  def require_admin!
    return if admin_token? || current_api_user&.admin?

    render json: { error: "forbidden: admin access required" }, status: :forbidden
  end

  def bearer_credentials
    header = request.headers["Authorization"].to_s
    scheme, _, credentials = header.partition(" ")
    scheme.casecmp("bearer").zero? ? credentials.to_s : nil
  end

  def admin_token_configured?
    ForgeCISecrets.fetch("admin_token").present?
  end

  def admin_token_matches?(provided)
    expected = ForgeCISecrets.fetch("admin_token").to_s
    expected.present? && provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end
end
