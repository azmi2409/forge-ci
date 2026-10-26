# frozen_string_literal: true

class RunnerInstance < ApplicationRecord
  ONLINE_FOR = 120.seconds
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  belongs_to :runner_token
  belongs_to :current_job_run, class_name: "JobRun", optional: true

  validates :uuid, presence: true, format: { with: UUID }
  validates :hostname, presence: true, length: { maximum: 255 }
  validates :implementation, inclusion: { in: %w[ruby go] }
  validates :last_seen_at, presence: true

  def active_job
    job = current_job_run
    job if job && JobRun::ACTIVE_STATUSES.include?(job.status) && job.claimed_by == runner_token.name
  end

  def status(now: Time.current)
    return "offline" if last_seen_at <= now - ONLINE_FOR

    active_job ? "busy" : "idle"
  end
end
