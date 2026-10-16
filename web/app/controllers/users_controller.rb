# frozen_string_literal: true

# User administration (admin only).
class UsersController < ApplicationController
  before_action :require_admin
  before_action :set_user, only: %i[edit update destroy]

  def index
    @users = User.order(:username)
  end

  def new
    @user = User.new(role: :member)
  end

  def create
    @user = User.new(username: params[:username], password: params[:password], role: safe_role)
    if params[:password] != params[:password_confirmation]
      @user.errors.add(:password, "and confirmation do not match")
      return render(:new, status: :unprocessable_entity)
    end

    if @user.save
      redirect_to users_path, notice: "User #{@user.username} created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    @user.role = safe_role if params[:role].present?
    if params[:password].present?
      if params[:password] != params[:password_confirmation]
        @user.errors.add(:password, "and confirmation do not match")
        return render(:edit, status: :unprocessable_entity)
      end
      @user.password = params[:password]
    end

    if @user.save
      redirect_to users_path, notice: "User #{@user.username} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @user == current_user
      redirect_to users_path, alert: "You cannot delete your own account."
    elsif @user.destroy
      redirect_to users_path, notice: "User #{@user.username} deleted."
    else
      redirect_to users_path, alert: @user.errors.full_messages.to_sentence
    end
  end

  private

  def set_user
    @user = User.find(params[:id])
  end

  def safe_role
    User.roles.key?(params[:role]) ? params[:role] : "member"
  end
end
