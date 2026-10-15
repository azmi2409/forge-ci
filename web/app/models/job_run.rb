# frozen_string_literal: true

# A single job execution inside a workflow run.
#
# Lifecycle (no state-machine gem — transitions are guarded explicitly):
#   pending -> queued -> claimed -> running -> success | failed | canceled
#   claimed -> success | failed | canceled   (runner reports without start)
#   claimed -> queued                        (stale-heartbeat reclaim)
#   pending|queued|claimed -> canceled
#
# Illegal transitions raise JobRun::IllegalTransition.
class JobRun < ApplicationRecord
  class IllegalTransition < StandardError; end

  # How long a claimed/running job may go without a heartbeat before the
  # reclaimer puts it back in the queue. Configurable; the recurring reclaim
  # job runs every RECLAIM_INTERVAL (see config/recurring.yml).
  STALE_HEARTBEAT_AFTER = 120.seconds
  RECLAIM_INTERVAL = 60.seconds

  ALLOWED_TRANSITIONS = {
    "pending" => %w[queued canceled],
    "queued" => %w[claimed canceled],
    # claimed -> terminal: the runner may report success/failure even if the
    # container never started (start call never happened).
    "claimed" => %w[running queued success failed canceled],
    "running" => %w[success failed canceled],
    "success" => [],
    "failed" => [],
    "canceled" => []
  }.freeze

  TERMINAL_STATUSES = %w[success failed canceled].freeze
  ACTIVE_STATUSES = %w[claimed running].freeze

  belongs_to :workflow_run
  has_one :pipeline, through: :workflow_run
  has_one :project, through: :pipeline
  has_many :step_runs, dependent: :destroy
  has_many :log_chunks, dependent: :destroy
  has_many :artifacts, dependent: :destroy

  enum :status, { pending: 0, queued: 1, claimed: 2, running: 3, success: 4, failed: 5, canceled: 6 }

  serialize :executor, coder: JSON
  serialize :steps, coder: JSON
  serialize :requires, coder: JSON
  serialize :context_environment, coder: JSON

  validates :name, presence: true, uniqueness: { scope: :workflow_run_id }

  # --- guarded transitions -------------------------------------------------

  def transition_to!(new_status, **attrs)
    new_status = new_status.to_s
    allowed = ALLOWED_TRANSITIONS.fetch(status)
    unless allowed.include?(new_status)
      raise IllegalTransition, "cannot transition job #{id} (#{name}) from #{status} to #{new_status}"
    end

    update!(attrs.merge(status: new_status))
  end

  def mark_queued!
    transition_to!("queued")
  end

  def mark_claimed!(claimed_by:)
    transition_to!("claimed", claimed_by: claimed_by, claimed_at: Time.current, heartbeat_at: Time.current)
  end

  def mark_running!
    transition_to!("running")
  end

  def cancel!
    transition_to!("canceled")
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # --- helpers ---------------------------------------------------------------

  def requires_list
    Array(requires).map(&:to_s)
  end

  def executor_hash
    executor || {}
  end

  # Executor environment merged with resolved context payloads; contexts win
  # on key conflicts. This is what the runner receives — never the raw
  # Context records.
  def merged_environment
    (executor_hash["environment"] || {}).merge(context_environment || {})
  end

  # --- claiming ----------------------------------------------------------------
  #
  # Postgres-first: the candidate scan takes FOR UPDATE SKIP LOCKED so two
  # runners racing for the same row resolve atomically (the loser simply sees
  # no claimable row). On other adapters (e.g. SQLite in local dev) the lock
  # clause is skipped — correctness then rests on the surrounding transaction
  # plus the reclaim safety net; see README.

  def self.postgres?
    connection.adapter_name == "PostgreSQL"
  end

  # Atomically claim the oldest queued job this token may run:
  #  - executor.resource_class matches the token's resource_class
  #    (a NULL on either side matches anything), and
  #  - the job's project still has a free max_concurrency slot
  #    (counted across claimed + running jobs).
  # Returns the claimed JobRun, or nil when nothing is claimable.
  def self.claim_next!(token)
    transaction do
      scope = queued.order(:created_at)
                    .preload(workflow_run: { pipeline: :project })
                    .where(
                      "job_runs.resource_class = :rc OR job_runs.resource_class IS NULL OR :rc IS NULL",
                      rc: token.resource_class
                    )
      scope = scope.lock("FOR UPDATE SKIP LOCKED") if postgres?

      job = scope.detect { |j| j.project.free_slots.positive? }
      return nil unless job

      job.mark_claimed!(claimed_by: token.name)
      job
    end
  end

  # --- completion ---------------------------------------------------------------

  # Record the runner's report, update step runs, unblock dependents whose
  # requires are now all successful, and roll statuses up to the workflow and
  # pipeline. Only valid from claimed/running; anything else raises
  # IllegalTransition.
  def complete_with_results!(status:, step_results: [])
    status = status.to_s
    unless TERMINAL_STATUSES.include?(status)
      raise IllegalTransition, "complete requires a terminal status, got #{status.inspect}"
    end

    transaction do
      Array(step_results).each do |sr|
        # Accept plain hashes (Ruby callers) and ActionController::Parameters
        # (HTTP) alike.
        sr = sr.respond_to?(:to_unsafe_h) ? sr.to_unsafe_h : sr.to_h
        name = sr["name"] || sr[:name]
        next if name.blank?

        step = step_runs.find_by(name: name.to_s)
        next unless step

        exit_code = sr["exit_code"] || sr[:exit_code]
        step.update!(
          exit_code: exit_code,
          started_at: sr["started_at"] || sr[:started_at],
          finished_at: sr["finished_at"] || sr[:finished_at],
          status: exit_code.to_i.zero? ? "success" : "failed"
        )
      end

      transition_to!(status)
      unblock_dependents! if status == "success"
      workflow_run.recompute_status!
      workflow_run.pipeline.recompute_status!
    end
  end

  # --- reclaim -------------------------------------------------------------------

  # Return stale claimed/running jobs (no heartbeat within STALE_HEARTBEAT_AFTER)
  # to queued so another runner can pick them up. Idempotent.
  def self.reclaim_stale!(older_than: STALE_HEARTBEAT_AFTER)
    where(status: ACTIVE_STATUSES)
      .where("heartbeat_at < ?", older_than.ago)
      .find_each do |job|
        job.transition_to!("queued", claimed_by: nil, claimed_at: nil, heartbeat_at: nil)
      end
  end

  private

  # Move pending jobs in this workflow to queued once every job they require
  # has succeeded. Called after a successful completion.
  def unblock_dependents!
    successful = workflow_run.job_runs.success.pluck(:name).to_set
    workflow_run.job_runs.pending.find_each do |job|
      job.mark_queued! if job.requires_list.all? { |r| successful.include?(r) }
    end
  end
end
