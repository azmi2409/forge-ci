# frozen_string_literal: true

class SweepJobLogsJob < ApplicationJob
  queue_as :default

  def perform
    JobRun.where(status: JobRun::TERMINAL_STATUSES).where("job_runs.updated_at < ?", 5.minutes.ago)
          .where(id: LogChunk.select(:job_run_id)).find_each do |job|
      FinalizeJobLogJob.perform_later(job.id)
    end
  end
end
