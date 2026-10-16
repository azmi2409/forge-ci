# frozen_string_literal: true

# Web UI base controller: cookie-session login (see Authentication, SessionsController).
class ApplicationController < ActionController::Base
  include Authentication

  # Don't let browsers/proxies cache authenticated pages.
  before_action { response.headers["Cache-Control"] = "no-store" }
end
