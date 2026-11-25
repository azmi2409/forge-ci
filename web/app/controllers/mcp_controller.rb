# frozen_string_literal: true

class McpController < ActionController::API
  before_action :validate_origin!, only: :dispatch_request
  before_action :prevent_caching, only: :dispatch_request
  include ApiAuthentication

  skip_before_action :authenticate_api!, only: %i[resource_metadata authorization_metadata]
  wrap_parameters false

  def dispatch_request
    server = MCP::Server.new(name: "forge-ci", title: "ForgeCI", tools: ForgeMcpTools.for(admin: api_admin?))
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server, stateless: true, enable_json_response: true, serve_subscriptions_listen: false,
      dns_rebinding_protection: false
    )
    status, headers, body = transport.call(request.env)
    headers.each { |key, value| response.set_header(key, value) }
    response.set_header("Allow", "POST") if status == 405
    self.status = status
    self.response_body = body
  end

  def resource_metadata
    render json: {
      resource: mcp_url, authorization_servers: [request.base_url],
      scopes_supported: ["mcp"], bearer_methods_supported: ["header"]
    }
  end

  def authorization_metadata
    render json: {
      issuer: request.base_url,
      authorization_endpoint: oauth_authorization_url,
      token_endpoint: oauth_token_url,
      revocation_endpoint: oauth_revoke_url,
      scopes_supported: %w[api mcp],
      response_types_supported: ["code"],
      grant_types_supported: %w[authorization_code refresh_token],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: %w[none client_secret_basic client_secret_post]
    }
  end

  private

  def validate_origin!
    origin = request.headers["Origin"]
    return if origin.nil? || origin == request.base_url

    render json: { error: "forbidden: invalid Origin" }, status: :forbidden
  end

  def prevent_caching
    response.set_header("Cache-Control", "no-store")
  end

  def unauthorized_api!
    response.set_header("WWW-Authenticate", %(Bearer resource_metadata="#{mcp_resource_metadata_url}", scope="mcp"))
    super
  end

  def api_oauth_scope_allowed?(token)
    token.scopes.exists?("mcp") || super
  end
end
