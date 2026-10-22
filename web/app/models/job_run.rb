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
  serialize :context_environment, coder: JSON

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
    finalize_log_blob! if TERMINAL_STATUSES.include?(new_status)
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
    rebuild_log_blob!
  end

  # Concatenate all chunks in seq order into the blob, replacing any
  # previous blob. Called on every chunk ingest; chatty jobs re-upload the
  # blob per chunk — correct for v1, and a documented candidate for a
  # delta-append optimization later.
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
      log_blob.download
    else
      ""
    end
  end

  def log_chunk_list
    rows = log_chunks.order(:seq).map { |c| { seq: c.seq, chunk: c.chunk } }
    return rows if rows.any?
    return [{ seq: 0, chunk: log_blob.download }] if log_blob.attached?

    []
  end

  # Write the final blob and drop the ingestion rows. Called automatically
  # when the job reaches a terminal state.
  def finalize_log_blob!
    rebuild_log_blob!
    log_chunks.delete_all
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
    variables = pipeline.forked? ? {} : project.variables_environment
    variables.merge(executor_hash["environment"] || {}).merge(context_environment || {})
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
      status == "success" ? unblock_dependents! : cancel_unreachable_dependents!
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
  # A job that failed/was canceled can never satisfy its dependents' requires,
  # so cancel the pending jobs that (transitively) wait on it instead of
  # leaving them pending forever.
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
