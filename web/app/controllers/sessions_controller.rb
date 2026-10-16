# frozen_string_literal: true

class SessionsController < ApplicationController
  skip_before_action :require_login, only: %i[new create]
  layout "auth"

  def new
    return redirect_to(projects_path) if signed_in?

    User.bootstrap_admin_from_env!
    @no_users = User.none?
  end

  def create
    User.bootstrap_admin_from_env!
    user = User.authenticate(params[:username], params[:password])
    if user
      return_to = SessionAuth.sign_in(self, user)
      redirect_to safe_return_path(return_to) || projects_path
    else
      @no_users = User.none?
      flash.now[:alert] = "Invalid username or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "Signed out."
  end

  private

  # Only same-site absolute paths — never an open redirect.
  def safe_return_path(path)
    path if path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") && !path.include?("\\")
  end
end
