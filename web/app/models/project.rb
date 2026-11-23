# frozen_string_literal: true

class Project < ApplicationRecord
  has_many :pipelines, dependent: :destroy
  has_many :workflow_runs, through: :pipelines
  has_many :job_runs, through: :workflow_runs
  has_many :contexts, dependent: :destroy
  has_many :variables, -> { order(:name) }, class_name: "ProjectVariable", dependent: :destroy
  has_many :cache_entries, dependent: :destroy
  has_many :github_repositories, dependent: :destroy

  validates :name, presence: true
  validates :max_concurrency, numericality: { only_integer: true, greater_than: 0 }

  # Context names injected into non-fork pipelines created from GitHub events.
  # Fork pull requests NEVER get these (see Github::SyncPipelineJob).
  def default_context_names
    contexts.pluck(:name)
  end

  # The dashboard's environment variables as a Hash of name => value.
  def variables_environment
    variables.to_h { |v| [v.name, v.value] }
  end

  def self.with_free_slots
    active_jobs = JobRun.joins(workflow_run: :pipeline)
                        .where(status: JobRun::ACTIVE_STATUSES)
                        .where(Pipeline.arel_table[:project_id].eq(arel_table[:id]))
    where("projects.max_concurrency > (#{active_jobs.select('COUNT(*)').to_sql})")
  end

  # The caller holds this reservation until its claim transaction commits.
  # At READ COMMITTED, count in a new statement after locking: the candidate
  # query's snapshot may predate the previous claimant's commit.
  def self.lock_claim_slot(project_id)
    project = lock("FOR NO KEY UPDATE SKIP LOCKED").find_by(id: project_id)
    project && project.free_slots.positive?
  end

  # Jobs currently occupying a concurrency slot.
  def active_job_count
    job_runs.where(status: JobRun::ACTIVE_STATUSES).count
  end

  def free_slots
    max_concurrency - active_job_count
  end
end
