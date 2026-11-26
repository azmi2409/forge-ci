# frozen_string_literal: true

module PipelineStatus
  SUMMARY_FIELDS = %i[id project_id sha branch status].freeze

  def self.list(project, limit:, **filters)
    project.pipelines.where(filters).select(*SUMMARY_FIELDS).order(id: :desc).limit(limit)
           .as_json(only: SUMMARY_FIELDS)
  end

  def self.detail(pipeline)
    {
      id: pipeline.id,
      project_id: pipeline.project_id,
      sha: pipeline.sha,
      branch: pipeline.branch,
      status: pipeline.status,
      workflows: pipeline.workflow_runs.map do |workflow|
        {
          id: workflow.id,
          name: workflow.name,
          status: workflow.status,
          jobs: workflow.job_runs.map { |job| job_detail(job) }
        }
      end
    }
  end

  def self.job_detail(job)
    {
      id: job.id, name: job.name, node_index: job.node_index, parallelism: job.parallelism,
      status: job.status, requires: job.requires_list,
      steps: job.step_runs.order(:id).map { |step| step.as_json(only: %i[name status exit_code]) }
    }
  end
end
