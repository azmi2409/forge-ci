# frozen_string_literal: true

class OauthAuthorizationsController < Doorkeeper::AuthorizationsController
  include OauthResourceIndicator

  prepend_before_action :validate_oauth_resource!, only: %i[new create destroy]
  before_action :prepare_mcp_scope!, only: %i[new create destroy]

  private

  def prepare_mcp_scope!
    return unless params[:client_id].is_a?(String)
    return unless Doorkeeper::Application.find_by(uid: params[:client_id])&.scopes&.to_s == "mcp"

    params[:scope] = "mcp" if params[:scope].blank?
    return if action_name == "destroy" || (params[:code_challenge].present? && params[:code_challenge_method] == "S256")

    render json: { error: "invalid_request", error_description: "MCP OAuth clients must use S256 PKCE." },
           status: :bad_request
  end
end
