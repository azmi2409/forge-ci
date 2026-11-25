# frozen_string_literal: true

module OauthLocalhostRedirects
  def loopback_uri?(uri)
    uri.hostname&.casecmp?("localhost") || super
  end
end

Doorkeeper::OAuth::Helpers::URIChecker.singleton_class.prepend(OauthLocalhostRedirects)

# OAuth provider for the forge-ci CLI (`forge-ci login`). The CLI is a public
# native client (RFC 8252): authorization-code grant with PKCE (S256 only)
# against the web UI's own session login, redirecting to a loopback port the
# CLI listens on. Tokens are accepted on the API by ApiAuthentication; the
# seeded client application itself lives in CliOauthApp.
Doorkeeper.configure do
  orm :active_record

  grant_flows %w[authorization_code]

  # The first-party CLI skips consent after web login. Other registered
  # clients, including MCP clients, go through Doorkeeper's consent screen.
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

  # Require PKCE with S256 for public clients such as the CLI.
  force_pkce
  pkce_code_challenge_methods %w[S256]

  # HTTPS except for loopback callbacks, including localhost. Doorkeeper
  # ignores the registered port for these callbacks (RFC 8252 §7.3).
  force_ssl_in_redirect_uri do |uri|
    !Doorkeeper::OAuth::Helpers::URIChecker.loopback_uri?(uri)
  end

  # Long-lived CLI sessions: short access tokens that refresh transparently.
  use_refresh_token
  access_token_expires_in 24.hours

  # Only token hashes are stored; the raw values exist solely in the CLI's
  # credentials file. (This rules out reuse_access_token, which we don't use.)
  hash_token_secrets
  hash_application_secrets

  default_scopes :api
  optional_scopes :mcp
end
