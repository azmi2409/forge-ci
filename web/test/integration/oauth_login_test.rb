# frozen_string_literal: true

require "test_helper"

require "base64"
require "openssl"
require "securerandom"

# End-to-end `forge-ci login` against a real Rails server: the authorization
# request lands on the UI login when signed out, bounces back after signing
# in, hands the loopback redirect a PKCE-bound code, and the code exchanges
# for a token the JSON API accepts.
class OAuthLoginTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "http://127.0.0.1:55555/callback"

  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @verifier = SecureRandom.urlsafe_base64(48)
    challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(@verifier), padding: false)
    @authorize_params = {
      client_id: CliOauthApp::UID,
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      scope: "api",
      state: "s3t4te",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }
  end

  # GET /oauth/authorize while signed out → /login → back to the very same
  # authorize request after signing in.
  test "the authorization round-trip goes through the UI login" do
    user = User.create!(username: "alice", password: TEST_PASSWORD, role: :admin)

    get "/oauth/authorize", params: @authorize_params
    assert_redirected_to "http://www.example.com/login"

    post "/login", params: { username: user.username, password: TEST_PASSWORD }
    assert_match(%r{\Ahttp://www\.example\.com/oauth/authorize\?client_id=#{CliOauthApp::UID}},
                 redirect_to_url, "returns to the authorize request")

    code = authorization_code
    assert_equal "s3t4te", code_query["state"], "state round-trips for CSRF protection"

    access_token = exchange_code(code)
    get "/api/v1/me", headers: bearer_headers(access_token)
    assert_response :ok
    assert_equal "alice", json_body["username"]
    assert_equal "admin", json_body["role"]
  end

  test "the CLI client is seeded by the first authorize request" do
    Doorkeeper::Application.where(uid: CliOauthApp::UID).delete_all
    get "/oauth/authorize", params: @authorize_params
    assert_redirected_to "/login", "still parked on login, not an invalid_client error"
    assert Doorkeeper::Application.exists?(uid: CliOauthApp::UID)
  end

  test "a member token can view and cancel but not start pipelines" do
    sign_in_as("bob", role: :member)
    code = authorization_code
    token = exchange_code(code)

    assert_no_difference -> { Pipeline.count } do
      post "/api/v1/projects/#{@project.id}/pipelines",
           params: { sha: "abc", branch: "main", ir: compile_test_ir },
           headers: bearer_headers(token), as: :json
    end
    assert_response :forbidden

    post "/api/v1/projects", params: { name: "nope" }, headers: bearer_headers(token), as: :json
    assert_response :forbidden

    get "/api/v1/projects", headers: bearer_headers(token)
    assert_response :ok

    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir },
         headers: admin_headers, as: :json
    assert_response :created
    pipeline_id = json_body["id"]

    get "/api/v1/pipelines/#{pipeline_id}", headers: bearer_headers(token)
    assert_response :ok
    post "/api/v1/pipelines/#{pipeline_id}/cancel", headers: bearer_headers(token)
    assert_response :ok
  end

  test "an admin token can start pipelines" do
    sign_in_as("carol", role: :admin)
    token = exchange_code(authorization_code)

    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir },
         headers: bearer_headers(token), as: :json
    assert_response :created
  end

  test "the shared admin token still authenticates" do
    get "/api/v1/me", headers: admin_headers
    assert_response :ok
    assert_equal true, json_body["admin_token"]
  end

  test "refresh tokens renew an expired access token" do
    sign_in_as("dave", role: :member)
    token = exchange_code(authorization_code)
    refresh = @last_token_response["refresh_token"]
    assert_not_nil refresh

    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: refresh,
      client_id: CliOauthApp::UID
    }
    assert_response :ok
    new_token = json_body["access_token"]
    assert_not_equal token, new_token

    get "/api/v1/me", headers: bearer_headers(new_token)
    assert_response :ok
    assert_equal "dave", json_body["username"]
  end

  test "revoking a token locks it out of the API" do
    sign_in_as("erin", role: :member)
    token = exchange_code(authorization_code)

    post "/oauth/revoke", params: { token: token, client_id: CliOauthApp::UID }
    assert_response :ok

    get "/api/v1/me", headers: bearer_headers(token)
    assert_response :unauthorized
  end

  test "PKCE is mandatory: no code_challenge is refused" do
    sign_in_as("frank", role: :admin)
    get "/oauth/authorize", params: @authorize_params.except(:code_challenge, :code_challenge_method)
    assert_response :bad_request
  end

  test "the plain code_challenge_method is refused" do
    sign_in_as("gina", role: :admin)
    get "/oauth/authorize", params: @authorize_params.merge(code_challenge_method: "plain")
    assert_response :bad_request
  end

  test "a wrong PKCE verifier cannot exchange the code" do
    sign_in_as("hank", role: :admin)
    code = authorization_code

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: CliOauthApp::UID,
      redirect_uri: REDIRECT_URI,
      code_verifier: "not-the-verifier"
    }
    assert_response :bad_request
  end

  test "an unregistered redirect_uri is refused" do
    sign_in_as("iris", role: :admin)
    get "/oauth/authorize", params: @authorize_params.merge(redirect_uri: "https://evil.example.com/cb")
    assert_response :bad_request
  end

  private

  # Signed-in authorize request → the code Doorkeeper redirected the
  # (loopback) user-agent with.
  def authorization_code
    get "/oauth/authorize", params: @authorize_params
    assert_response :redirect, "expected a redirect to the loopback callback"
    assert_match(%r{\A#{REDIRECT_URI}\?}, redirect_to_url,
                 "redirects to the registered loopback URI (any port matches)")
    assert_not_nil code_query["code"], redirect_to_url
    code_query["code"]
  end

  def code_query
    @code_query ||= Rack::Utils.parse_query(URI.parse(redirect_to_url).query)
  end

  def exchange_code(code)
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: CliOauthApp::UID,
      redirect_uri: REDIRECT_URI,
      code_verifier: @verifier
    }
    assert_response :ok, "code exchange failed: #{response.body}"
    body = json_body
    assert_equal "Bearer", body["token_type"]
    assert_equal "api", body["scope"]
    @last_token_response = body
    body["access_token"]
  end
end
