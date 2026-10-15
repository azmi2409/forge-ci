# frozen_string_literal: true

# Web UI base controller. HTTP basic auth for the whole UI; credentials come
# from FORGE_CI_UI_USER / FORGE_CI_UI_PASSWORD. Real auth (login, RBAC) is
# deferred — see README.
class ApplicationController < ActionController::Base
  before_action :require_ui_auth

  private

  def require_ui_auth
    user = ENV["FORGE_CI_UI_USER"]
    password = ENV["FORGE_CI_UI_PASSWORD"]

    if user.blank? || password.blank?
      if Rails.env.production?
        render plain: "UI auth not configured (set FORGE_CI_UI_USER / FORGE_CI_UI_PASSWORD)", status: :internal_server_error
        return
      end
      Rails.logger.warn "[forge-ci] FORGE_CI_UI_USER/PASSWORD not set — using dev default admin / password"
      user, password = "admin", "password"
    end

    authenticate_or_request_with_http_basic do |u, p|
      ActiveSupport::SecurityUtils.secure_compare(u.to_s, user) &
        ActiveSupport::SecurityUtils.secure_compare(p.to_s, password)
    end
  end
end
