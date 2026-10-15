# frozen_string_literal: true

class Project < ApplicationRecord
  has_many :pipelines, dependent: :destroy
  has_many :workflow_runs, through: :pipelines
  has_many :job_runs, through: :workflow_runs
  has_many :contexts, dependent: :destroy
  has_many :cache_entries, dependent: :destroy
  has_many :github_repositories, dependent: :destroy

  validates :name, presence: true
  validates :max_concurrency, numericality: { only_integer: true, greater_than: 0 }

  # Context names injected into non-fork pipelines created from GitHub events.
  # Fork pull requests NEVER get these (see Github::SyncPipelineJob).
  def default_context_names
    contexts.pluck(:name)
  end

  # Jobs currently occupying a concurrency slot.
  def active_job_count
    job_runs.where(status: %w[claimed running]).count
  end

  def free_slots
    max_concurrency - active_job_count
  end
end
