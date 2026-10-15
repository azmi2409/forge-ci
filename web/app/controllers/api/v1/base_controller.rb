# frozen_string_literal: true

module Api
  module V1
    # Base for authenticated runner endpoints. Every request needs
    # `Authorization: Bearer <raw-runner-token>`.
    class BaseController < ActionController::API
      before_action :authenticate_runner!

      private

      attr_reader :current_runner_token

      def authenticate_runner!
        raw = bearer_token
        @current_runner_token = RunnerToken.authenticate(raw)
        render json: { error: "unauthorized: valid bearer token required" }, status: :unauthorized unless @current_runner_token
      end

      def bearer_token
        header = request.headers["Authorization"].to_s
        scheme, _, credentials = header.partition(" ")
        return nil unless scheme.casecmp("bearer").zero?

        credentials.presence
      end

      # The job must belong to the token making the request; otherwise 403.
      # (A token can only ever claim jobs, so non-owners get "forbidden".)
      def require_job_owner!(job)
        return if job.claimed_by == current_runner_token.name

        render json: { error: "forbidden: job is owned by another token" }, status: :forbidden
      end
    end
  end
end
