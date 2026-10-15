# frozen_string_literal: true

module Api
  module V1
    # Context (secret set) administration (component 8).
    #
    # Auth is a dedicated admin token, NOT a runner token: runner tokens
    # must never be able to read or rewrite secrets. Set FORGE_CI_ADMIN_TOKEN
    # in production; the endpoint refuses to serve (503) when it is blank —
    # fail-closed, never fail-open.
    class ContextsController < ActionController::API
      before_action :authenticate_admin!

      # POST /api/v1/contexts/:id/rotate { payload: { "KEY": "new-value", ... } }
      # Replaces the encrypted payload wholesale (Rails `encrypts` at rest).
      # Responds with key NAMES only — values are never echoed back.
      def rotate
        context = Context.find(params[:id])
        payload = params[:payload]
        unless payload.is_a?(ActionController::Parameters) || payload.is_a?(Hash)
          return render json: { error: "payload must be an object of KEY => value" },
                        status: :unprocessable_entity
        end

        clean = payload.to_unsafe_h.transform_keys(&:to_s).transform_values(&:to_s)
        if clean.empty? || clean.keys.any?(&:blank?)
          return render json: { error: "payload must not be empty and keys must not be blank" },
                        status: :unprocessable_entity
        end

        context.payload = clean
        context.save!
        render json: {
          id: context.id,
          name: context.name,
          keys: context.payload.keys.sort,
          updated_at: context.updated_at
        }, status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: "context not found" }, status: :not_found
      end

      private

      def authenticate_admin!
        expected = ENV["FORGE_CI_ADMIN_TOKEN"].to_s
        if expected.blank?
          return render json: { error: "admin API not configured (set FORGE_CI_ADMIN_TOKEN)" },
                        status: :service_unavailable
        end

        header = request.headers["Authorization"].to_s
        scheme, _, credentials = header.partition(" ")
        provided = scheme.casecmp("bearer").zero? ? credentials.to_s : nil
        unless provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)
          render json: { error: "unauthorized: valid admin bearer <redacted> required" }, status: :unauthorized
        end
      end
    end
  end
end
