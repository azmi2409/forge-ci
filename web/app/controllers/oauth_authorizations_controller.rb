# frozen_string_literal: true

class OauthAuthorizationsController < Doorkeeper::AuthorizationsController
  include OauthResourceIndicator

  prepend_before_action :validate_oauth_resource!, only: %i[new create destroy]
  before_action :prepare_mcp_scope!, only: %i[new create destroy]

  private

  def prepare_mcp_scope!
    if params[:scope].blank? && params[:client_id].is_a?(String)
      app = Doorkeeper::Application.find_by(uid: params[:client_id])
      params[:scope] = "mcp" if app&.scopes&.to_s == "mcp"
    end
    return unless params[:scope].is_a?(String) && params[:scope].split.include?("mcp")

    return if action_name == "destroy" || valid_s256_challenge?

    render json: { error: "invalid_request", error_description: "MCP OAuth clients must use S256 PKCE." },
           status: :bad_request
  end

  def valid_s256_challenge?
    challenge = params[:code_challenge]
    params[:code_challenge_method] == "S256" && challenge.is_a?(String) && challenge.match?(/\A[A-Za-z0-9_-]{43}\z/)
  end
end
