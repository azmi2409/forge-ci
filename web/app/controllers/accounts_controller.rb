# frozen_string_literal: true

# The signed-in user's own account: change password, sign out everywhere.
class AccountsController < ApplicationController
  def show; end

  def update
    user = current_user
    unless User.digest_matches?(user.password_digest, params[:current_password])
      flash.now[:alert] = "Current password is incorrect."
      return render :show, status: :unprocessable_entity
    end
    if params[:password] != params[:password_confirmation]
      flash.now[:alert] = "New password and confirmation do not match."
      return render :show, status: :unprocessable_entity
    end

    user.password = params[:password]
    if user.save
      # Password change rotated the nonce; keep *this* browser signed in.
      SessionAuth.sign_in(self, user)
      redirect_to account_path, notice: "Password changed. Other sessions were signed out."
    else
      flash.now[:alert] = user.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  def sign_out_everywhere
    current_user.rotate_session_nonce!
    SessionAuth.sign_in(self, current_user.reload)
    redirect_to account_path, notice: "All other sessions were signed out."
  end
end
