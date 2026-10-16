# frozen_string_literal: true

# Signed + encrypted cookie session. Set FORCE_SSL=true behind an HTTPS
# terminator (Coolify, nginx, ...) to mark the cookie Secure and enable HSTS.
Rails.application.config.session_store :cookie_store,
                                       key: "_forge_ci_session",
                                       httponly: true,
                                       same_site: :lax,
                                       secure: ENV["FORCE_SSL"] == "true",
                                       expire_after: 7.days # keep in sync with SessionAuth::ABSOLUTE_TIMEOUT
