# frozen_string_literal: true

class ProjectsController < ApplicationController
  RECENT_PIPELINES = 20
  PROJECT_PIPELINES = 50

  def index
    @projects = Project.order(:name).to_a
    @last_pipelines = Pipeline.where(id: Pipeline.group(:project_id).select("MAX(id)"))
                              .index_by(&:project_id)
    @pipeline_counts = Pipeline.group(:project_id).count
    @recent = Pipeline.includes(:project).order(created_at: :desc).limit(RECENT_PIPELINES)
    @stats = dashboard_stats
  end

  def show
    @project = Project.find(params[:id])
    @pipelines = @project.pipelines.order(created_at: :desc).limit(PROJECT_PIPELINES)
    @total = @project.pipelines.count
  end

  private

  def dashboard_stats
    day = Pipeline.where(created_at: 24.hours.ago..)
    finished = day.where(status: %w[success failed]).group(:status).count
    done = finished.values.sum
    {
      projects: @projects.size,
      running: Pipeline.where(status: "running").count,
      today: day.count,
      success_rate: done.zero? ? nil : (100.0 * finished.fetch("success", 0) / done).round
    }
  end
end
