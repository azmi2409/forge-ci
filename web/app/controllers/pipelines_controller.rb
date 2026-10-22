# frozen_string_literal: true

class PipelinesController < ApplicationController
  def show
    @project = Project.find(params[:project_id])
    @pipeline = @project.pipelines.find(params[:id])
    @workflows = @pipeline.workflow_runs.includes(job_runs: :step_runs).order(:id)
  end

  def rerun
    project = Project.find(params[:project_id])
    pipeline = project.pipelines.find(params[:id])
    only_failed = params[:scope] != "all"
    count = pipeline.rerun!(only_failed: only_failed)
    notice = count.zero? ? "Nothing to rerun." : "Rerunning #{count == 1 ? '1 job' : "#{count} jobs"}#{' that failed' if only_failed}."
    redirect_to project_pipeline_path(project, pipeline), notice: notice
  rescue ArgumentError
    redirect_to project_pipeline_path(project, pipeline), alert: "Wait for the pipeline to finish, or cancel it, before rerunning."
  end

  def cancel
    project = Project.find(params[:project_id])
    pipeline = project.pipelines.find(params[:id])
    pipeline.cancel!
    redirect_to project_pipeline_path(project, pipeline), notice: "Pipeline canceled."
  end
end
