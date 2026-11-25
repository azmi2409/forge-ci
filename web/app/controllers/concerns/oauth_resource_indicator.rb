# frozen_string_literal: true

module OauthResourceIndicator
  private

  def validate_oauth_resource!
    return unless params.key?(:resource)
    return if params[:resource] == main_app.mcp_url

    response.set_header("Cache-Control", "no-store")
    render json: { error: "invalid_target", error_description: "The requested OAuth resource is not supported." },
           status: :bad_request
  end
end
