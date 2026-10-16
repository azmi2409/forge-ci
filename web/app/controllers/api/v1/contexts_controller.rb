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
      include AdminAuthentication

      # POST /api/v1/projects/:project_id/contexts { name:, payload: {KEY: value} }
      # Creates a context (or replaces the payload of an existing one with the
      # same name). Responds with key NAMES only.
      def create
        project = Project.find(params[:project_id])
        clean = clean_payload
        return render_bad_payload unless clean

        context = project.contexts.find_or_initialize_by(name: params[:name].to_s)
        context.payload = clean
        context.save!
        render json: context_json(context), status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "project not found" }, status: :not_found
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "invalid context", details: e.record.errors.full_messages },
               status: :unprocessable_entity
      end

      # POST /api/v1/contexts/:id/rotate { payload: { "KEY": "new-value", ... } }
      # Replaces the encrypted payload wholesale (Rails `encrypts` at rest).
      # Responds with key NAMES only — values are never echoed back.
      def rotate
        context = Context.find(params[:id])
        clean = clean_payload
        return render_bad_payload unless clean

        context.payload = clean
        context.save!
        render json: context_json(context), status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: "context not found" }, status: :not_found
      end

      private

      # Validated payload hash, or nil when malformed.
      def clean_payload
        payload = params[:payload]
        return nil unless payload.is_a?(ActionController::Parameters) || payload.is_a?(Hash)

        clean = payload.to_unsafe_h.transform_keys(&:to_s).transform_values(&:to_s)
        clean.empty? || clean.keys.any?(&:blank?) ? nil : clean
      end

      def render_bad_payload
        render json: { error: "payload must be a non-empty object of KEY => value with non-blank keys" },
               status: :unprocessable_entity
      end

      def context_json(context)
        { id: context.id, name: context.name, project_id: context.project_id,
          keys: context.payload.keys.sort, updated_at: context.updated_at }
      end
    end
  end
end
