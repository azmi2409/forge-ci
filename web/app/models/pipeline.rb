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
      if workflow_runs.where(status: %w[pending running]).exists?
        "running"
      elsif workflow_runs.failed.exists?
        "failed"
      elsif workflow_runs.canceled.exists?
        "canceled"
      else
        "success"
      end
    update!(status: new_status) if status != new_status
  end

  # Cancel every job that has not finished yet. Jobs already running are
  # marked canceled here; the runner notices on its next heartbeat and
  # stops the container. Returns self.
  def cancel!
    transaction do
      job_runs.where.not(status: JobRun::TERMINAL_STATUSES).find_each(&:cancel!)
      workflow_runs.each(&:recompute_status!)
      recompute_status!
    end
    self
  end

  # Run a finished pipeline's jobs again, in place (so workspaces and the
  # commit status carry over): the jobs that didn't succeed, with every node
  # of a parallel job, or with only_failed: false every job. Jobs whose
  # requires already succeeded are queued now; the rest wait for them.
  # Returns the number of jobs reset.
  def rerun!(only_failed: true)
    raise ArgumentError, "pipeline #{id} hasn't finished yet" unless terminal?

    reset = 0
    transaction do
      workflow_runs.includes(:job_runs).each do |workflow|
        by_name = workflow.job_runs.group_by(&:name)
        rerun_names = by_name.keys.select { |name| !only_failed || !by_name[name].all?(&:success?) }
        next if rerun_names.empty?

        done = by_name.keys - rerun_names
        rerun_names.each do |name|
          by_name[name].each do |job|
            job.reset_for_rerun!
            job.mark_queued! if job.requires_list.all? { |r| done.include?(r) }
            reset += 1
          end
        end
        workflow.recompute_status!
      end
      recompute_status!
    end
    Github::StatusPoster.post_pending(self) if reset.positive?
    reset
  end

  private

  def post_github_status
    return unless terminal?

    Github::StatusPoster.post_terminal(self)
  rescue StandardError => e
    Rails.logger.error("[github] commit status post failed for pipeline #{id}: #{e.class}: #{e.message}")
  end
end
