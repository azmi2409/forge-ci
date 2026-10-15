# frozen_string_literal: true

module Github
  # Posts forge-ci commit statuses to GitHub for pipelines created from
  # GitHub events. One status context ("forge-ci") per pipeline.
  #
  # Called explicitly with :pending right after intake, and via
  # Pipeline#after_update_commit for terminal statuses. No-op for pipelines
  # that did not originate from a GitHub repository. Failures are logged,
  # never raised — a status post must not break the pipeline itself.
  class StatusPoster
    CONTEXT = "forge-ci"

    STATE_FOR_STATUS = {
      "pending" => "pending",
      "running" => "pending",
      "success" => "success",
      "failed" => "failure",
      "canceled" => "error"
    }.freeze

    def self.post_pending(pipeline)
      post(pipeline, state: "pending", description: "forge-ci build queued")
    end

    def self.post_terminal(pipeline)
      state = STATE_FOR_STATUS.fetch(pipeline.status, "error")
      description =
        case pipeline.status
        when "success" then "forge-ci build passed"
        when "failed" then "forge-ci build failed"
        else "forge-ci build #{pipeline.status}"
        end
      post(pipeline, state: state, description: description)
    end

    # Used when config compilation fails: still create the failed pipeline
    # and tell GitHub why, instead of silently dropping the push.
    def self.post_compile_error(pipeline, errors)
      first_lines = Array(errors).first(2).join("; ")
      post(pipeline, state: "failure", description: "config error: #{first_lines}")
    end

    def self.post(pipeline, state:, description:)
      repo = pipeline.github_repository
      return false unless repo

      installation = repo.github_installation
      client = Github.client_for(installation.installation_id)
      client.create_commit_status(
        repo.full_name,
        pipeline.sha,
        state: state,
        description: description,
        target_url: pipeline_url(pipeline),
        context: CONTEXT
      )
      true
    rescue StandardError => e
      Rails.logger.error("[github] commit status #{state} failed for pipeline #{pipeline.id}: #{e.class}: #{e.message}")
      false
    end

    def self.pipeline_url(pipeline)
      host = Github.app_host
      return nil if host.blank?

      # Host may be given with or without scheme.
      base = host.start_with?("http") ? host : "https://#{host}"
      "#{base}/projects/#{pipeline.project_id}/pipelines/#{pipeline.id}"
    end
    private_class_method :post, :pipeline_url
  end
end
