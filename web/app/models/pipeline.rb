# frozen_string_literal: true

class Pipeline < ApplicationRecord
  belongs_to :project
  belongs_to :github_repository, optional: true
  has_many :workflow_runs, dependent: :destroy
  has_many :job_runs, through: :workflow_runs

  enum :status, { pending: 0, running: 1, success: 2, failed: 3, canceled: 4 }

  validates :sha, :branch, presence: true

  TERMINAL_STATUSES = %w[success failed canceled].freeze

  # Report terminal statuses back to GitHub as commit statuses (component 3).
  # after_update_commit runs outside the completion transaction, so the HTTP
  # call never blocks or rolls back job completion. No-op for pipelines that
  # did not come from a GitHub repo.
  after_update_commit :post_github_status, if: :saved_change_to_status?

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

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

  private

  def post_github_status
    return unless terminal?

    Github::StatusPoster.post_terminal(self)
  rescue StandardError => e
    Rails.logger.error("[github] commit status post failed for pipeline #{id}: #{e.class}: #{e.message}")
  end
end
