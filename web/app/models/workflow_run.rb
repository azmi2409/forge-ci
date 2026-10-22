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

  # Jobs laid out for the pipeline graph: an array of stages (columns), each
  # an array of node groups (all JobRuns of one job name, so a parallel job
  # is one entry). A job's stage is one past the deepest job it requires;
  # requires that name no job in this workflow are ignored.
  def stages
    groups = job_runs.sort_by(&:id).group_by(&:name)
    depth = {}
    depth_of = lambda do |name, seen|
      return depth[name] if depth.key?(name)
      return 0 if seen.include?(name) # defensive: the compiler rejects cycles

      parents = groups[name].first.requires_list.select { |r| groups.key?(r) }
      depth[name] = parents.empty? ? 0 : parents.map { |r| depth_of.call(r, seen + [name]) }.max + 1
    end
    groups.each_key { |name| depth_of.call(name, []) }
    groups.group_by { |name, _| depth[name] }.sort.map { |_d, entries| entries.map(&:last) }
  end
end
