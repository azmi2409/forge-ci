# frozen_string_literal: true

# Live log notices for the job page: {event: "chunk", seq} when output
# arrives and {event: "done", status} when the job finishes. They carry no
# log text (Postgres NOTIFY payloads are capped at 8 KB); the page fetches
# the new chunks from GET /api/v1/jobs/:id/logs?after=SEQ.
class JobLogChannel < ApplicationCable::Channel
  def self.stream_name(job_id)
    "job_log:#{job_id}"
  end

  # Never lets a broadcast problem break log ingest or a job transition.
  def self.notify(job_id, payload)
    ActionCable.server.broadcast(stream_name(job_id), payload)
  rescue StandardError => e
    Rails.logger.warn("[cable] job #{job_id} notify failed: #{e.class}: #{e.message}")
  end

  def subscribed
    job = JobRun.find_by(id: params[:job_id])
    job ? stream_from(self.class.stream_name(job.id)) : reject
  end
end
