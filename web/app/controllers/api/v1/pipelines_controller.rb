# frozen_string_literal: true

module Api
  module V1
    # Pipeline intake (`forge-ci trigger` / curl) plus status and cancel.
    # Admin-token authed (FORGE_CI_ADMIN_TOKEN); the GitHub flow does not use
    # this controller — it goes through the HMAC-verified webhook. Accepts the
    # compiler IR as JSON.
    class PipelinesController < ActionController::API
      include AdminAuthentication

      def show
        render json: pipeline_json(Pipeline.find(params[:id]))
      rescue ActiveRecord::RecordNotFound
        render json: { error: "pipeline not found" }, status: :not_found
      end

      def cancel
        pipeline = Pipeline.find(params[:id])
        pipeline.cancel!
        render json: pipeline_json(pipeline.reload)
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
        render json: pipeline_json(pipeline), status: :created
      rescue ActiveRecord::RecordNotFound
        render json: { error: "project not found" }, status: :not_found
      rescue PipelineIntake::IntakeError => e
        render json: { error: e.message, details: e.details }, status: e.http_status
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "invalid pipeline", details: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def pipeline_json(pipeline)
        {
          id: pipeline.id,
          project_id: pipeline.project_id,
          sha: pipeline.sha,
          branch: pipeline.branch,
          status: pipeline.status,
          workflows: pipeline.workflow_runs.map do |wf|
            {
              id: wf.id,
              name: wf.name,
              status: wf.status,
              jobs: wf.job_runs.map do |job|
                { id: job.id, name: job.name, status: job.status, requires: job.requires_list }
              end
            }
          end
        }
      end
    end
  end
end
