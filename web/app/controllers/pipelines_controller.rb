# frozen_string_literal: true

class PipelinesController < ApplicationController
  def show
    @project = Project.find(params[:project_id])
    @pipeline = @project.pipelines.find(params[:id])
    @workflows = @pipeline.workflow_runs.includes(job_runs: :step_runs).order(:id)
  end

  def cancel
    project = Project.find(params[:project_id])
    pipeline = project.pipelines.find(params[:id])
    pipeline.cancel!
    redirect_to project_pipeline_path(project, pipeline), notice: "Pipeline canceled."
  end
end
