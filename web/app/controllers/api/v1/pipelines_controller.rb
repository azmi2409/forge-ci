# frozen_string_literal: true

module Api
  module V1
    # Pipeline intake — the seam the GitHub App (component 3) calls.
    # Unauthenticated in v1 (auth is deferred, see README); accepts the
    # compiler IR as JSON.
    class PipelinesController < ActionController::API
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
