# frozen_string_literal: true

# A single job execution inside a workflow run.
#
# Lifecycle (no state-machine gem — transitions are guarded explicitly):
#   pending -> queued -> claimed -> running -> success | failed | canceled
#   claimed -> success | failed | canceled   (runner reports without start)
#   claimed -> queued                        (stale-heartbeat reclaim, release)
#   running -> queued                        (release)
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

  # How many times runners may hand one job back to the queue (release!)
  # before it has to finish where it is.
  MAX_RELEASES = 2

  ALLOWED_TRANSITIONS = {
    "pending" => %w[queued canceled],
    "queued" => %w[claimed canceled],
    # claimed -> terminal: the runner may report success/failure even if the
    # container never started (start call never happened).
    "claimed" => %w[running queued success failed canceled],
    # running -> queued only through release! (opt-in, see there).
    "running" => %w[success failed canceled queued],
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

  # Durable log store (component 6). LogChunk rows remain as the write-ahead
  # ingestion buffer — idempotent upserts keyed on (job_run_id, seq) give us
  # ordering and safe retries — while the blob is the source of truth for
  # reads. Rows are purged once the job reaches a terminal state and the
  # final blob is written (see finalize_log_blob!).
  has_one_attached :log_blob

  enum :status, { pending: 0, queued: 1, claimed: 2, running: 3, success: 4, failed: 5, canceled: 6 }

  serialize :executor, coder: JSON
  serialize :steps, coder: JSON
  serialize :requires, coder: JSON
  serialize :encrypted_context_environment, coder: JSON
  encrypts :encrypted_context_environment
  alias_attribute :context_environment, :encrypted_context_environment

  self.filter_attributes += %i[context_environment encrypted_context_environment]

  # Runner claims expose the merged environment explicitly, never generic serialization.
  def serializable_hash(options = nil)
    super.except("context_environment", "encrypted_context_environment")
  end

  validates :name, presence: true, uniqueness: { scope: %i[workflow_run_id node_index] }
  validates :parallelism, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :node_index, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than: :parallelism }

  # --- guarded transitions -------------------------------------------------

  def transition_to!(new_status, **attrs)
    new_status = new_status.to_s
    allowed = ALLOWED_TRANSITIONS.fetch(status)
    unless allowed.include?(new_status)
      raise IllegalTransition, "cannot transition job #{id} (#{name}) from #{status} to #{new_status}"
    end

    update!(attrs.merge(status: new_status))
    # Durable log store: once terminal, the blob holds the final log and the
    # ingestion rows are dropped (see #finalize_log_blob!).
    return unless TERMINAL_STATUSES.include?(new_status)

    finalize_log_blob!
    JobLogChannel.notify(id, event: "done", status: new_status)
  end

  # "test" or, for a parallel job, "test [2/4]" (1-based for people).
  def display_name
    parallelism > 1 ? "#{name} [#{node_index + 1}/#{parallelism}]" : name
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
    step_runs.where(status: "pending").update_all(status: StepRun.statuses.fetch("canceled"))
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # --- log storage (component 6) ------------------------------------------------

  # Idempotent chunk ingest: upsert the row, then rebuild the blob from all
  # ordered chunks. Retried seqs overwrite the row (upsert) and the rebuild
  # keeps the blob consistent — never duplicated, always in seq order.
  def append_log_chunk!(seq, chunk)
    LogChunk.upsert(
      { job_run_id: id, seq: seq.to_i, chunk: chunk.to_s,
        created_at: Time.current, updated_at: Time.current },
      unique_by: :index_log_chunks_on_job_run_id_and_seq
    )
    # The rows are the durable store until the job finishes; the blob is
    # written once then (finalize_log_blob!), not on every chunk.
    JobLogChannel.notify(id, event: "chunk", seq: seq.to_i)
  end

  # Concatenate all chunks in seq order into the blob, replacing any
  # previous blob. Called once, when the job finishes.
  def rebuild_log_blob!
    text = log_chunks.order(:seq).map(&:chunk).join
    log_blob.attach(
      io: StringIO.new(text),
      filename: "job-#{id}.log",
      content_type: "text/plain"
    )
  end

  # Full log text: buffered rows while they exist, the blob after they're
  # purged (job terminal), empty string when there's no output at all.
  def log_text
    if log_chunks.exists?
      log_chunks.order(:seq).map(&:chunk).join
    elsif log_blob.attached?
      stored_log_text
    else
      ""
    end
  end

  # Chunks after +after+ (all by default). Once the job has finished the
  # rows are gone and the whole log comes back as one chunk; callers that
  # pass +after+ should replace what they have when #log_complete? is true.
  def log_chunk_list(after: nil)
    rows = log_chunks.order(:seq)
    rows = rows.where("seq > ?", after.to_i) unless after.nil?
    rows = rows.map { |c| { seq: c.seq, chunk: c.chunk } }
    return rows if rows.any? || !log_complete?

    [{ seq: 0, chunk: stored_log_text }]
  end

  # The log lives in the blob: the job finished and its rows were dropped.
  def log_complete?
    log_blob.attached? && !log_chunks.exists?
  end

  # The finished log from storage. Downloads come back as binary
  # (ASCII-8BIT); logs are UTF-8 text, with any invalid bytes replaced so
  # odd job output can't break the page that shows it.
  def stored_log_text
    log_blob.download.force_encoding(Encoding::UTF_8).scrub
  end

  # Write the final blob and drop the ingestion rows. Called automatically
  # when the job reaches a terminal state.
  def finalize_log_blob!
    rebuild_log_blob!
    log_chunks.delete_all
  end

  # Back to pending for a rerun, as if never run: no runner, logs, artifacts
  # or step results. Deliberately outside the state machine, which only moves
  # forward. Pipeline#rerun! queues it again once its requires are met.
  def reset_for_rerun!
    log_chunks.delete_all
    artifacts.destroy_all
    log_blob.purge if log_blob.attached?
    step_runs.update_all(status: StepRun.statuses.fetch("pending"), exit_code: nil,
                         started_at: nil, finished_at: nil, updated_at: Time.current)
    update_columns(status: "pending", claimed_by: nil, claimed_at: nil, heartbeat_at: nil, updated_at: Time.current)
  end

  # --- release ------------------------------------------------------------------

  # A runner that is shutting down (e.g. a Spot instance being reclaimed)
  # hands its job back: the job goes to queued, as if never run, for another
  # runner to start over. Only runners with REQUEUE_ON_SHUTDOWN call this.
  # It is opt-in because a running job that dies is otherwise failed, never
  # retried: its steps may have done part of their work (half a deploy).
  # Only runners whose jobs are safe to run twice opt in.
  #
  # Returns false, changing nothing, once the job has been released
  # MAX_RELEASES times. Only valid from claimed/running; anything else
  # raises IllegalTransition.
  def release!(reason: nil)
    unless ACTIVE_STATUSES.include?(status)
      raise IllegalTransition, "cannot release job #{id} (#{name}) from #{status}"
    end
    return false if releases >= MAX_RELEASES

    transaction do
      log_chunks.delete_all
      artifacts.destroy_all
      log_blob.purge if log_blob.attached?
      step_runs.update_all(status: StepRun.statuses.fetch("pending"), exit_code: nil,
                           started_at: nil, finished_at: nil, updated_at: Time.current)
      transition_to!("queued", claimed_by: nil, claimed_at: nil, heartbeat_at: nil, releases: releases + 1)
      workflow_run.recompute_status!
      workflow_run.pipeline.recompute_status!
    end
    Rails.logger.info("[release] job #{id} (#{display_name}) back to the queue " \
                      "(release #{releases} of #{MAX_RELEASES}): #{reason.presence || "no reason given"}")
    # The job page starts its log over.
    JobLogChannel.notify(id, event: "requeued")
    true
  end

  # --- helpers ---------------------------------------------------------------

  def requires_list
    Array(requires).map(&:to_s)
  end

  def executor_hash
    executor || {}
  end

  # What the runner receives as the job's environment, lowest precedence
  # first: the project's dashboard variables (read now, never for fork pull
  # requests), the executor environment from the config, then resolved
  # context payloads. Never the raw ProjectVariable or Context records.
  def merged_environment
    return executor_hash["environment"] || {} if pipeline.forked?

    project.variables_environment.merge(executor_hash["environment"] || {}).merge(context_environment || {})
  end

  # Explicit secret values let runners redact short project/context secrets
  # without guessing that every short environment value is sensitive.
  def secret_values
    return [] if pipeline.forked?

    project_values = project.variables_environment
    context_values = context_environment || {}
    effective = project_values.merge(executor_hash["environment"] || {}).merge(context_values)

    project_values.merge(context_values).filter_map do |key, value|
      value = value.to_s
      value if !value.empty? && effective[key].to_s == value
    end.uniq
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
  #  - fork-only tokens run only forks; all other tokens run only trusted pipelines,
  #  - executor.resource_class matches the token's resource_class, or, for
  #    a token without one (e.g. the shared FORGE_CI_RUNNER_TOKEN), the
  #    class the runner asked for (a NULL on either side matches anything), and
  #  - the job's project still has a free max_concurrency slot
  #    (counted across claimed + running jobs).
  # Returns the claimed JobRun, or nil when nothing is claimable.
  def self.claim_next!(token, requested_resource_class: nil)
    resource_class = token.resource_class || requested_resource_class.presence
    transaction do
      scope = queued.order(:created_at)
                    .preload(workflow_run: { pipeline: :project })
      scope = scope.where(workflow_run_id: WorkflowRun.joins(:pipeline).where(pipelines: { forked: token.fork_only? }).select(:id))
      # NULL on either side matches anything. A NULL token class needs no
      # filter at all; binding NULL into `OR :rc IS NULL` makes Postgres
      # unable to infer the parameter type (PG::IndeterminateDatatype).
      unless resource_class.nil?
        scope = scope.where(
          "job_runs.resource_class = ? OR job_runs.resource_class IS NULL",
          resource_class
        )
      end
      scope = scope.lock("FOR UPDATE SKIP LOCKED") if postgres?

      job = scope.detect { |j| j.project.free_slots.positive? }
      return nil unless job

      job.mark_claimed!(claimed_by: token.name)
      job
    end
  end

  # Jobs of +resource_class+ waiting on earlier jobs (pending) that a runner
  # of that class will get soon. Lets a warmed-up runner stay up for them and
  # the autoscaler start one early (FORGE_CI_AUTOSCALE_WARM). Only recent
  # jobs count, so a stuck old pipeline can't keep a runner up forever.
  UPCOMING_WINDOW = 2.hours

  def self.upcoming_count(resource_class, fork_only: nil)
    scope = pending.where(created_at: UPCOMING_WINDOW.ago..)
    unless fork_only.nil?
      scope = scope.where(workflow_run_id: WorkflowRun.joins(:pipeline).where(pipelines: { forked: fork_only }).select(:id))
    end
    scope = scope.where(resource_class: resource_class) unless resource_class.nil?
    scope.count
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
      cancel_sibling_nodes! if status == "failed"
      status == "success" ? unblock_dependents! : cancel_unreachable_dependents!
      workflow_run.recompute_status!
      workflow_run.pipeline.recompute_status!
    end
  end

  # --- reclaim -------------------------------------------------------------------

  # Jobs whose runner stopped heartbeating (none within STALE_HEARTBEAT_AFTER):
  #  - claimed but never started: back to queued for another runner;
  #  - running: failed, with a note in the log. Its steps may have done part
  #    of their work (half a deploy), so it isn't retried automatically;
  #    "Rerun failed jobs" is one click away.
  # Each job is handled on its own, so one can't stop the rest. Idempotent.
  def self.reclaim_stale!(older_than: STALE_HEARTBEAT_AFTER)
    where(status: ACTIVE_STATUSES)
      .where("heartbeat_at < ?", older_than.ago)
      .find_each do |job|
        job.reclaim_stale!
      rescue StandardError => e
        Rails.logger.error("[reclaim] job #{job.id} (#{job.name}): #{e.class}: #{e.message}")
      end
  end

  def reclaim_stale!
    if claimed?
      transition_to!("queued", claimed_by: nil, claimed_at: nil, heartbeat_at: nil)
    else
      seq = log_chunks.maximum(:seq).to_i + 1
      log_chunks.create!(seq: seq, chunk: "\n[forge-ci] the runner (#{claimed_by}) stopped responding " \
                                         "while this job was running; marking it failed. Rerun it to try again.\n")
      step_runs.where(status: %w[pending running]).update_all(status: StepRun.statuses.fetch("canceled"))
      complete_with_results!(status: "failed")
    end
  end

  private

  # Move pending jobs in this workflow to queued once every job they require
  # has succeeded. Called after a successful completion.
  # A job that failed/was canceled can never satisfy its dependents' requires,
  # so cancel the pending jobs that (transitively) wait on it instead of
  # leaving them pending forever.
  # One failed node fails a parallel job, so its other nodes can't change the
  # outcome: cancel them instead of letting them hold runners. Running nodes
  # stop at their runner's next heartbeat.
  def cancel_sibling_nodes!
    return if parallelism <= 1

    workflow_run.job_runs.where(name: name).where.not(id: id)
                .where.not(status: TERMINAL_STATUSES).find_each(&:cancel!)
  end

  def cancel_unreachable_dependents!
    loop do
      dead = workflow_run.job_runs.where(status: %w[failed canceled]).pluck(:name).to_set
      doomed = workflow_run.job_runs.pending.select { |j| j.requires_list.any? { |r| dead.include?(r) } }
      break if doomed.empty?

      doomed.each(&:cancel!)
    end
  end

  # A required job counts as successful only once every one of its
  # parallel nodes has succeeded.
  def unblock_dependents!
    successful = workflow_run.job_runs.pluck(:name, :status)
                             .group_by(&:first)
                             .select { |_name, rows| rows.all? { |_n, status| status == "success" } }
                             .keys.to_set
    workflow_run.job_runs.pending.find_each do |job|
      job.mark_queued! if job.requires_list.all? { |r| successful.include?(r) }
    end
  end
end
