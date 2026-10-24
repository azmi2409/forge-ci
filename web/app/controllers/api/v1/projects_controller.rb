# frozen_string_literal: true

module Api
  module V1
    # Project listing/creation so a fresh install can be set up without a
    # Rails console. ApiAuthentication: listing is open to any authenticated
    # token (the CLI resolves --project names with it), creating needs an
    # admin.
    class ProjectsController < ActionController::API
      include ApiAuthentication
      before_action :require_admin!, only: %i[create]

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
