# frozen_string_literal: true

require "test_helper"

class OauthClientRegistrationTest < ActionDispatch::IntegrationTest
  test "a confidential registered client must use S256 and prove possession of its verifier" do
    callback = "https://agent.example/callback"
    post "/oauth/register", params: {
      client_name: "Confidential agent", redirect_uris: [callback],
      token_endpoint_auth_method: "client_secret_post", response_types: ["code"], scope: "mcp"
    }, as: :json
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    client = json_body
    assert_equal ["authorization_code"], client["grant_types"]
    secret = client.fetch("client_secret")
    assert_equal 0, client["client_secret_expires_at"]
    application = Doorkeeper::Application.find_by!(uid: client.fetch("client_id"))
    assert application.confidential?
    assert_not_equal secret, application.secret
    assert_equal application, Doorkeeper::Application.by_uid_and_secret(application.uid, secret)
    assert_nil Doorkeeper::Application.by_uid_and_secret(application.uid, nil)

    sign_in_as
    authorization = { client_id: application.uid, redirect_uri: callback, response_type: "code" }
    get "/oauth/authorize", params: authorization
    assert_response :bad_request
    assert_equal "invalid_request", json_body["error"]

    verifier = SecureRandom.urlsafe_base64(48)
    challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
    get "/oauth/authorize", params: authorization.merge(code_challenge: challenge, code_challenge_method: "plain")
    assert_response :bad_request
    authorization.merge!(code_challenge: challenge, code_challenge_method: "S256")
    get "/oauth/authorize", params: authorization
    assert_response :ok
    post "/oauth/authorize", params: authorization
    assert_response :redirect

    code = URI.decode_www_form(URI(redirect_to_url).query).to_h.fetch("code")
    grant = Doorkeeper::AccessGrant.by_token(code)
    assert_equal challenge, grant.code_challenge
    assert_equal "S256", grant.code_challenge_method
    exchange = { grant_type: "authorization_code", code: code, redirect_uri: callback,
                 client_id: application.uid, client_secret: secret }
    post "/oauth/token", params: exchange
    assert_response :bad_request
    post "/oauth/token", params: exchange.merge(code_verifier: SecureRandom.urlsafe_base64(48))
    assert_response :bad_request
    assert_equal "invalid_grant", json_body["error"]
    post "/oauth/token", params: exchange.merge(code_verifier: verifier)
    assert_response :ok
    assert_equal "mcp", json_body["scope"]
    assert_not json_body.key?("refresh_token")
    assert_nil Doorkeeper::AccessToken.by_token(json_body.fetch("access_token")).refresh_token
  end

  test "a confidential client configured for other scopes also needs S256 when requesting MCP" do
    sign_in_as
    app = Doorkeeper::Application.create!(name: "Manually configured agent", redirect_uri: "https://agent.example/callback",
                                         scopes: "api mcp", confidential: true)
    get "/oauth/authorize", params: { client_id: app.uid, redirect_uri: app.redirect_uri, response_type: "code", scope: "api mcp" }
    assert_response :bad_request
    assert_equal "invalid_request", json_body["error"]
  end

  test "registration rejects unsafe redirects and metadata outside the MCP OAuth flow" do
    assert_no_difference -> { Doorkeeper::Application.count } do
      [
        "http://agent.example/callback", "http://localhost.evil.example/callback",
        "https://trusted.example@agent.example/callback", "https://agent.example/callback#fragment",
        "https://agent.example/callback https://other.example/callback", "javascript:alert(1)"
      ].each do |redirect|
        post "/oauth/register", params: { redirect_uris: [redirect] }, as: :json
        assert_response :bad_request
        assert_equal "invalid_redirect_uri", json_body["error"]
      end
      %i[scope grant_types response_types token_endpoint_auth_method].zip([
        "api", ["client_credentials"], ["token"], "private_key_jwt"
      ]).each do |field, value|
        post "/oauth/register", params: { redirect_uris: ["https://agent.example/callback"], field => value }, as: :json
        assert_response :bad_request
        assert_equal "invalid_client_metadata", json_body["error"]
      end
    end
  end

  test "registration has a 16 KiB body limit and rejects malformed JSON" do
    headers = { "Content-Type" => "application/json" }
    post "/oauth/register", params: "x" * (16.kilobytes + 1), headers: headers
    assert_response 413
    post "/oauth/register", params: "{", headers: headers
    assert_response :bad_request
    assert_equal "invalid_client_metadata", json_body["error"]
  end

  test "registration is rate limited per IP" do
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    OauthClientRegistration::MAX_REGISTRATIONS.times do
      post "/oauth/register", params: {}, as: :json
      assert_response :bad_request
    end
    post "/oauth/register", params: {}, as: :json
    assert_response :too_many_requests
    assert_equal OauthClientRegistration::RATE_WINDOW.to_i.to_s, response.headers["Retry-After"]
  ensure
    Rails.cache = previous_cache
  end
end
