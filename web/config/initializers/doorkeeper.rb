# frozen_string_literal: true

# OAuth provider for the forge-ci CLI (`forge-ci login`). The CLI is a public
# native client (RFC 8252): authorization-code grant with PKCE (S256 only)
# against the web UI's own session login, redirecting to a loopback port the
# CLI listens on. Tokens are accepted on the API by ApiAuthentication; the
# seeded client application itself lives in CliOauthApp.
Doorkeeper.configure do
  orm :active_record

  grant_flows %w[authorization_code]

  # The CLI app is the only client. Its authorization step is the web UI's
  # own login: once the resource owner is signed in there is nothing left to
  # consent to, so no consent screen is shown.
  skip_authorization do |_resource_owner, client|
    client.uid == CliOauthApp::UID
  end

  # Sign-in reuses the UI session (SessionAuth). Unauthenticated
  # /oauth/authorize requests are parked on /login with a return path and
  # come straight back after signing in; the performed redirect halts the
  # callback chain, so falling through with nil is fine.
  resource_owner_authenticator do
    # The seeded CLI client (see CliOauthApp): this block runs before the
    # request's client is looked up, so bootstrapping here covers installs
    # that never touched /login since the feature shipped.
    CliOauthApp.bootstrap!
    SessionAuth.user_for(session) || begin
      session[:return_to] = request.fullpath if request.get? && !request.xhr?
      redirect_to(main_app.login_url)
      nil
    end
  end

  # The CLI cannot keep a client secret: public client, PKCE mandatory, and
  # only the S256 challenge method (never "plain").
  force_pkce
  pkce_code_challenge_methods %w[S256]

  # HTTPS redirect URIs everywhere except the CLI's loopback callback
  # (RFC 8252 §7.3: the port is ignored too, so the CLI binds an ephemeral
  # one; see URIChecker.matches?).
  force_ssl_in_redirect_uri do |uri|
    !Doorkeeper::OAuth::Helpers::URIChecker.loopback_uri?(uri)
  end

  # Long-lived CLI sessions: short access tokens that refresh transparently.
  use_refresh_token
  access_token_expires_in 24.hours

  # Only token hashes are stored; the raw values exist solely in the CLI's
  # credentials file. (This rules out reuse_access_token, which we don't use.)
  hash_token_secrets

  default_scopes :api
end
