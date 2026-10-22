# frozen_string_literal: true

# Raises runner Auto Scaling Groups when jobs queue (see RunnerAutoscaler).
# A no-op unless FORGE_CI_AUTOSCALE is set.
class ScaleRunnersJob < ApplicationJob
  queue_as :default

  def perform
    return unless RunnerAutoscaler.enabled?

    RunnerAutoscaler.new.call
  rescue StandardError => e
    # AWS hiccups must not wedge the recurring schedule; the next run retries.
    Rails.logger.error("[autoscale] #{e.class}: #{e.message}")
  end
end
