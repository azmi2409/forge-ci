# frozen_string_literal: true

module Api
  module V1
    # Base for authenticated runner endpoints. Every request needs
    # `Authorization: Bearer <raw-runner-token>`.
    class BaseController < ActionController::API
      before_action :authenticate_runner!
      before_action :set_active_storage_url_options

      private

      attr_reader :current_runner_token

      # The Disk ActiveStorage service builds signed URLs from
      # ActiveStorage::Current.url_options — nothing sets it automatically,
      # so derive it from the request (the S3 service ignores it).
      def set_active_storage_url_options
        ActiveStorage::Current.url_options = { protocol: request.protocol, host: request.host_with_port }
      end

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
