# frozen_string_literal: true

class OauthClientRegistrationsController < ActionController::Metal
  AUTH_METHODS = %w[none client_secret_basic client_secret_post].freeze
  GRANT_TYPES = %w[authorization_code refresh_token].freeze
  MAX_BODY_BYTES = 16.kilobytes
  MAX_REGISTRATIONS = 20
  RATE_WINDOW = 5.minutes
  HEADERS = { "content-type" => "application/json", "cache-control" => "no-store", "pragma" => "no-cache" }.freeze

  def create
    return error(429, "temporarily_unavailable", "Too many registration attempts.", "retry-after" => RATE_WINDOW.to_i.to_s) if rate_limited?
    return error(415, "invalid_client_metadata", "Expected application/json.") unless request.media_type == "application/json"
    return body_too_large if request.content_length > MAX_BODY_BYTES

    body = request.body.read(MAX_BODY_BYTES + 1).to_s
    return body_too_large if body.bytesize > MAX_BODY_BYTES

    metadata = JSON.parse(body, max_nesting: 16)
    return error(400, "invalid_client_metadata", "Expected a JSON object.") unless metadata.is_a?(Hash)

    redirects = metadata["redirect_uris"]
    unless redirects.is_a?(Array) && redirects.size.between?(1, 8) && redirects.all? { |uri| web_callback?(uri) }
      return invalid_redirect
    end

    name = metadata.fetch("client_name", "MCP client")
    method = metadata.fetch("token_endpoint_auth_method", "client_secret_basic")
    grants = metadata.fetch("grant_types", ["authorization_code"])
    unless name.is_a?(String) && name.bytesize <= 200 && name.present? && !name.match?(/[[:cntrl:]]/) &&
           AUTH_METHODS.include?(method) && grants.is_a?(Array) &&
           grants.include?("authorization_code") && (grants - GRANT_TYPES).empty? &&
           metadata.fetch("response_types", ["code"]) == ["code"] && metadata.fetch("scope", "mcp") == "mcp"
      return error(400, "invalid_client_metadata", "Only authorization code, optional refresh tokens, and the mcp scope are supported.")
    end

    app = Doorkeeper::Application.create!(
      name: name, redirect_uri: redirects.uniq, scopes: "mcp", confidential: method != "none",
      refresh_token_enabled: grants.include?("refresh_token")
    )
    registration = {
      client_id: app.uid, client_id_issued_at: app.created_at.to_i, client_name: app.name,
      redirect_uris: redirects.uniq, scope: "mcp", token_endpoint_auth_method: method,
      response_types: ["code"], grant_types: grants.uniq
    }
    registration.merge!(client_secret: app.plaintext_secret, client_secret_expires_at: 0) if app.confidential?
    respond_json(201, registration)
  rescue JSON::ParserError
    error(400, "invalid_client_metadata", "Malformed JSON.")
  rescue ActiveRecord::RecordInvalid => e
    return invalid_redirect if e.record.errors[:redirect_uri].any?

    error(400, "invalid_client_metadata", "The OAuth client could not be registered.")
  end

  private

  def rate_limited?
    key = "oauth-client-registration:#{request.remote_ip}"
    Rails.cache.increment(key, 1, expires_in: RATE_WINDOW).to_i > MAX_REGISTRATIONS
  end

  def web_callback?(value)
    return false unless value.is_a?(String) && value.bytesize <= 2.kilobytes && !value.match?(/[[:space:][:cntrl:]]/)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.userinfo.nil?
  rescue URI::InvalidURIError
    false
  end

  def body_too_large
    error(413, "invalid_client_metadata", "Registration body exceeds 16 KiB.")
  end

  def invalid_redirect
    error(400, "invalid_redirect_uri", "Use HTTPS or an HTTP loopback callback, without userinfo or fragments.")
  end

  def error(status, code, description, headers = {})
    respond_json(status, { error: code, error_description: description }, headers)
  end

  def respond_json(status, body, extra_headers = {})
    headers.merge!(HEADERS).merge!(extra_headers)
    self.status = status
    self.response_body = body.to_json
  end
end
