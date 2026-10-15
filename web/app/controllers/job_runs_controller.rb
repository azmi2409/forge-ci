# frozen_string_literal: true

class JobRunsController < ApplicationController
  def show
    @job = JobRun.includes(:step_runs, :log_chunks, workflow_run: :pipeline).find(params[:id])
    @chunks = @job.log_chunks.order(:seq)
  end
end
