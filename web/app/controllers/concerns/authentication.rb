# frozen_string_literal: true

# Session login for the web UI. Include in a controller to require a signed-in
# user for every action (opt out with skip_before_action :require_login).
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_login
    helper_method :current_user, :signed_in?
  end

  private

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = SessionAuth.user_for(session)
  end

  def signed_in?
    current_user.present?
  end

  def require_login
    return if signed_in?

    reset_session if session[:user_id] # stale/expired session
    session[:return_to] = request.fullpath if request.get? && !request.xhr?
    redirect_to login_path
  end

  def require_admin
    return if current_user&.admin?

    redirect_to root_path_for_user, alert: "Admin access required."
  end

  def root_path_for_user
    projects_path
  end
end
