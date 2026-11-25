# frozen_string_literal: true

require "test_helper"

class OauthClientRegistrationTest < ActionDispatch::IntegrationTest
  test "a confidential registration returns a secret usable only with the registered client" do
    post "/oauth/register", params: {
      client_name: "Confidential agent", redirect_uris: ["https://agent.example/callback"],
      token_endpoint_auth_method: "client_secret_post", response_types: ["code"], scope: "mcp"
    }, as: :json
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    client = json_body
    secret = client.fetch("client_secret")
    assert_equal 0, client["client_secret_expires_at"]
    application = Doorkeeper::Application.find_by!(uid: client.fetch("client_id"))
    assert application.confidential?
    assert_not_equal secret, application.secret
    assert_equal application, Doorkeeper::Application.by_uid_and_secret(application.uid, secret)
    assert_nil Doorkeeper::Application.by_uid_and_secret(application.uid, nil)
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
