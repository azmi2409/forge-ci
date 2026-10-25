# frozen_string_literal: true

# The OAuth client `forge-ci login` talks to: a seeded Doorkeeper application
# (public client, PKCE-only, scope "api") rather than a user-registered one —
# the applications management UI is not exposed. Created lazily and
# idempotently from the resource_owner_authenticator block (runs on every
# /oauth/authorize, before the client is looked up), so a fresh install is
# ready the first time a CLI logs in.
class CliOauthApp
  UID = "forge-ci-cli"
  # Loopback redirect per RFC 8252 §7.3 (any port matches, so the CLI binds
  # an ephemeral one), plus the out-of-band redirect for `forge-ci login
  # --manual` over SSH: Doorkeeper then shows the code on a page to copy.
  REDIRECT_URI = "http://127.0.0.1/callback urn:ietf:wg:oauth:2.0:oob"

  def self.bootstrap!
    app = Doorkeeper::Application.find_or_create_by!(uid: UID) do |record|
      record.name = "forge-ci CLI"
      record.redirect_uri = REDIRECT_URI
      record.confidential = false
      record.scopes = "api"
    end
    # Keep the seeded client current when the shipped redirect URIs change.
    app.update!(redirect_uri: REDIRECT_URI) if app.redirect_uri != REDIRECT_URI
    app
  rescue ActiveRecord::RecordNotUnique
    # Two processes bootstrapping at once: the other one's record is equally
    # good.
    Doorkeeper::Application.find_by!(uid: UID)
  end
end
