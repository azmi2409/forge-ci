# frozen_string_literal: true

module Api
  module V1
    # Project administration (admin-token authed) so a fresh install can be
    # set up without a Rails console.
    class ProjectsController < ActionController::API
      include AdminAuthentication

      def index
        render json: { projects: Project.order(:name).map { |p| project_json(p) } }
      end

      # POST /api/v1/projects { name, repo_url?, default_branch?, max_concurrency? }
      def create
        project = Project.new(params.permit(:name, :repo_url, :default_branch, :max_concurrency))
        project.max_concurrency ||= 4
        if Project.exists?(name: project.name)
          return render json: { error: "invalid project", details: ["Name has already been taken"] },
                        status: :unprocessable_entity
        end
        project.save!
        render json: project_json(project), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: "invalid project", details: e.record.errors.full_messages },
               status: :unprocessable_entity
      end

      private

      def project_json(project)
        project.slice(:id, :name, :repo_url, :default_branch, :max_concurrency)
      end
    end
  end
end
