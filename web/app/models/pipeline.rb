# frozen_string_literal: true

class Pipeline < ApplicationRecord
  belongs_to :project
  has_many :workflow_runs, dependent: :destroy
  has_many :job_runs, through: :workflow_runs

  enum :status, { pending: 0, running: 1, success: 2, failed: 3, canceled: 4 }

  validates :sha, :branch, presence: true

  # Roll up workflow statuses. Called inside the job-completion transaction.
  def recompute_status!
    new_status =
      if workflow_runs.failed.exists?
        "failed"
      elsif workflow_runs.canceled.exists?
        "canceled"
      elsif workflow_runs.where(status: %w[pending running]).exists?
        "running"
      else
        "success"
      end
    update!(status: new_status) if status != new_status
  end
end
