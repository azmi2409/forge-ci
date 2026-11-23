# frozen_string_literal: true

module Github
  # Keeps the "forge-ci" commit status on GitHub in step with pipelines
  # created from GitHub events.
  #
  # The post methods record the wanted state (GithubCommitStatus) and queue
  # DeliverCommitStatusJob, which calls GitHub and retries transient
  # failures. Callers run after their intake or completion transaction has
  # committed, so GitHub is never called while job or repository rows are
  # locked. No-op for pipelines that did not originate from a GitHub
  # repository.
  class StatusPoster
    CONTEXT = "forge-ci"

    STATE_FOR_STATUS = {
      "pending" => "pending",
      "running" => "pending",
      "success" => "success",
      "failed" => "failure",
      "canceled" => "error"
    }.freeze

    # Skipped once the pipeline has finished: a build can finish before its
    # intake gets here. The row lock orders this against the completion,
    # whose callback then records the result after it.
    def self.post_pending(pipeline)
      return unless pipeline.github_repository

      status = pipeline.with_lock do
        unless pipeline.terminal?
          GithubCommitStatus.record!(pipeline, state: "pending", description: "forge-ci build queued")
        end
      end
      DeliverCommitStatusJob.perform_later(status.id) if status
      status
    end

    def self.post_terminal(pipeline)
      state = STATE_FOR_STATUS.fetch(pipeline.status, "error")
      description =
        case pipeline.status
        when "success" then "forge-ci build passed"
        when "failed" then "forge-ci build failed"
        else "forge-ci build #{pipeline.status}"
        end
      publish(pipeline, state: state, description: description)
    end

    # Used when config compilation fails: still create the failed pipeline
    # and tell GitHub why, instead of silently dropping the push.
    def self.post_compile_error(pipeline, errors)
      first_lines = Array(errors).first(2).join("; ")
      publish(pipeline, state: "failure", description: "config error: #{first_lines}")
    end

    # For a webhook delivered again for a commit that already has a pipeline:
    # queue the status again if GitHub never received it.
    def self.redeliver(pipeline)
      status = pipeline.github_commit_status
      if status.nil?
        pipeline.terminal? ? post_terminal(pipeline) : post_pending(pipeline)
      elsif !status.delivered?
        DeliverCommitStatusJob.perform_later(status.id)
      end
    end

    # Post the status's current state to GitHub. Raises
    # AppClient::TransientError for DeliverCommitStatusJob to retry; other
    # API errors are logged and kept on the row.
    def self.deliver(status)
      return if status.delivered?

      generation = status.generation
      pipeline = status.pipeline
      repo = pipeline.github_repository
      return unless repo

      client = Github.client_for(repo.github_installation.installation_id)
      client.create_commit_status(
        repo.full_name,
        pipeline.sha,
        state: status.state,
        description: status.description,
        target_url: pipeline_url(pipeline),
        context: CONTEXT
      )
      status.mark_delivered!(generation)
    rescue AppClient::TransientError => e
      Rails.logger.warn("[github] commit status #{status.state} for pipeline #{status.pipeline_id} will be retried: #{e.message}")
      status.mark_failed!(generation, e)
      raise
    rescue AppClient::ApiError, AppClient::NotConfigured => e
      Rails.logger.error("[github] commit status #{status.state} failed for pipeline #{status.pipeline_id}: #{e.class}: #{e.message}")
      status.mark_failed!(generation, e)
    end

    def self.publish(pipeline, state:, description:)
      return unless pipeline.github_repository

      status = GithubCommitStatus.record!(pipeline, state: state, description: description)
      DeliverCommitStatusJob.perform_later(status.id)
      status
    end

    def self.pipeline_url(pipeline)
      host = Github.app_host
      return nil if host.blank?

      # Host may be given with or without scheme.
      base = host.start_with?("http") ? host : "https://#{host}"
      "#{base}/projects/#{pipeline.project_id}/pipelines/#{pipeline.id}"
    end
    private_class_method :publish, :pipeline_url
  end
end
