# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/queue — jobs waiting and in flight per resource class, for
    # autoscalers (built-in RunnerAutoscaler or your own). Admin-token authed.
    #   { "resource_classes": { "spot": { "queued": 3, "running": 1 }, "any": {...} } }
    # "any" is jobs without a resource_class, which any runner may claim.
    class QueueController < ActionController::API
      include AdminAuthentication

      def show
        counts = JobRun.where(status: %w[queued claimed running]).group(:resource_class, :status).count
        classes = Hash.new { |h, k| h[k] = { queued: 0, running: 0 } }
        counts.each do |(klass, status), n|
          bucket = status.to_s == "queued" ? :queued : :running
          classes[klass || "any"][bucket] += n
        end
        render json: { resource_classes: classes }
      end
    end
  end
end
