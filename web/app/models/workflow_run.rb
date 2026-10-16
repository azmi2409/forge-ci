# frozen_string_literal: true

class WorkflowRun < ApplicationRecord
  belongs_to :pipeline
  has_many :job_runs, dependent: :destroy
  has_one :project, through: :pipeline

  enum :status, { pending: 0, running: 1, success: 2, failed: 3, canceled: 4 }

  validates :name, presence: true, uniqueness: { scope: :pipeline_id }

  # Roll up job statuses: running while any job is still in flight, then
  # failed wins over canceled, else success. (Waiting for in-flight jobs
  # keeps the terminal status — and the GitHub commit status — from firing
  # while work is still running.)
  def recompute_status!
    jobs = job_runs
    new_status =
      if jobs.where(status: %w[pending queued claimed running]).exists?
        "running"
      elsif jobs.failed.exists?
        "failed"
      elsif jobs.canceled.exists?
        "canceled"
      else
        "success"
      end
    update!(status: new_status) if status != new_status
  end
end
