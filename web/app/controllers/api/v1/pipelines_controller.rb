# frozen_string_literal: true

module Api
  module V1
    # Pipeline intake (`forge-ci trigger` / curl) plus status and cancel.
    # ApiAuthentication: the shared admin token, or an OAuth token from
    # `forge-ci login` (starting a pipeline needs an admin; status and cancel
    # are open to members). The GitHub flow does not use this controller —
    # it goes through the HMAC-verified webhook. Accepts the compiler IR as
    # JSON.
    class PipelinesController < ActionController::API
      include ApiAuthentication
      before_action :require_admin!, only: %i[create]

      def index
        project = Project.find(params[:project_id])
        limit = params.fetch(:limit, "20")
        unless (limit.is_a?(Integer) || (limit.is_a?(String) && /\A[0-9]+\z/.match?(limit))) &&
               limit.to_i.between?(1, 100)
          return render json: { error: "limit must be an integer between 1 and 100" }, status: :bad_request
        end

        filters = {}
        %i[branch sha].each do |filter|
          next unless params.key?(filter)
          unless params[filter].is_a?(String)
            return render json: { error: "#{filter} must be a string" }, status: :bad_request
          end

          filters[filter] = params[filter]
        end

        render json: { pipelines: PipelineStatus.list(project, limit: limit.to_i, **filters) }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "project not found" }, status: :not_found
      end

      def show
        render json: PipelineStatus.detail(Pipeline.find(params[:id]))
      rescue ActiveRecord::RecordNotFound
        render json: { error: "pipeline not found" }, status: :not_found
      end

      def cancel
        pipeline = Pipeline.find(params[:id])
        pipeline.cancel!
        render json: PipelineStatus.detail(pipeline.reload)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "pipeline not found" }, status: :not_found
      end

      def create
        project = Project.find(params[:project_id])
        pipeline = PipelineIntake.call!(
          project: project,
          sha: params[:sha],
          branch: params[:branch],
          ir: params[:ir],
          context_names: params[:contexts]
        )
        render json: PipelineStatus.detail(pipeline), status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "project not found" }, status: :not_found
      rescue PipelineIntake::IntakeError => e
        render json: { error: e.message, details: e.details }, status: e.http_status
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "invalid pipeline", details: e.record.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end
end
