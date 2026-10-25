# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/me — who the presented token authenticates as. `forge-ci
    # login` verifies the flow with this and reports the user; it doubles as
    # a cheap "is my token still valid" probe for scripts.
    class MeController < ActionController::API
      include ApiAuthentication

      def show
        if admin_token?
          render json: { admin_token: true, role: "admin" }
        else
          render json: { username: current_api_user.username, role: current_api_user.role }
        end
      end
    end
  end
end
