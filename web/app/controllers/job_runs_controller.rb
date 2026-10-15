# frozen_string_literal: true

class JobRunsController < ApplicationController
  def show
    @job = JobRun.includes(:step_runs, workflow_run: :pipeline).find(params[:id])
    # Initial render comes from the blob (terminal jobs) or buffered rows.
    @initial_log = @job.log_text
  end
end
