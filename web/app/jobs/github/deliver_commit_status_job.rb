# frozen_string_literal: true

module Github
  # Posts a pipeline's recorded commit status to GitHub (see StatusPoster).
  #
  # GitHub rate limits, 5xx responses and network errors are retried with
  # backoff for about four hours; any other API error is kept on the row and
  # not retried. One delivery per status runs at a time, so a slow post of
  # an older state can never land after a newer one.
  class DeliverCommitStatusJob < ApplicationJob
    queue_as :default
    limits_concurrency to: 1, key: ->(status_id) { status_id }

    retry_on AppClient::TransientError, wait: :polynomially_longer, attempts: 10 do |job, error|
      Rails.logger.error("[github] giving up on commit status #{job.arguments.first} after " \
                         "#{job.executions} attempts: #{error.message}")
    end

    def perform(status_id)
      status = GithubCommitStatus.find_by(id: status_id)
      StatusPoster.deliver(status) if status
    end
  end
end
