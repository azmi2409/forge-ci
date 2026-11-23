# frozen_string_literal: true

module Api
  module V1
    # Log streaming (component 6).
    #
    # Chunk ingest accepts the owning runner's Bearer token. Reads also
    # accept API credentials and a signed-in UI session,
    # so the job page can tail logs without holding a runner token (browsers
    # send the session cookie on same-origin EventSource requests, but cannot
    # set an Authorization: Bearer header).
    class JobsController < BaseController
      include ActionController::Live
      include ApiAuthentication

      skip_before_action :authenticate_api!

      # How long a live-tail stream stays open waiting for new output. Each
      # open stream holds one of Puma's threads, so this stays short and the
      # job page reconnects (it re-sends from the start; the page dedupes by
      # seq). Env-overridable (seconds).
      def stream_timeout
        ENV.fetch("FORGE_CI_STREAM_TIMEOUT_SECONDS", "25").to_i.seconds
      end

      before_action :find_job_or_404, only: %i[stream logs]
      before_action :authenticate_stream!, only: %i[stream logs]
      around_action :with_owned_job_lock, only: :create_log_chunk

      # `stream` has its own dual auth (Bearer token OR UI session);
      # skip the base class's Bearer-only check for it.
      skip_before_action :authenticate_runner!, only: %i[stream logs]

      # POST /api/v1/jobs/:id/log_chunks { seq:, chunk: }
      # Idempotent on (job_run_id, seq); the blob is rebuilt in seq order.
      def create_log_chunk
        seq = params[:seq]
        chunk = params[:chunk]
        unless seq.present? && chunk.present?
          return render json: { error: "seq and chunk are required" }, status: :unprocessable_entity
        end

        @job.append_log_chunk!(seq, chunk)
        render json: { job_id: @job.id, seq: seq.to_i }, status: :ok
      end

      # GET /api/v1/jobs/:id/logs -> { chunks: [{seq, chunk}] } ordered by seq.
      # Reads buffered rows until the finalizer verifies the blob;
      # then reads from the blob. Simple polling is the fallback
      # live-tail story.
      # ?after=SEQ returns only newer chunks (the job page's live view);
      # complete: true means the job finished and `chunks` is the whole log.
      def logs
        after = params[:after].presence&.to_i
        chunks = @job.log_chunk_list(after: after)
        steps = @job.step_runs.order(:id).map { |step| step.as_json(only: %i[name status exit_code]) }
        render json: { job_id: @job.id, status: @job.status, claimed_at: @job.claimed_at&.iso8601(6),
                       complete: @job.log_complete?, chunks: chunks, steps: steps }, status: :ok
      end

      # GET /api/v1/jobs/:id/logs/stream — text/event-stream live tail.
      # Sends existing chunks as `chunk` events, then polls for new ones
      # until the job is terminal (then a `done` event) or the client
      # disconnects / the timeout elapses.
      def stream
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        sse = ActionController::Live::SSE.new(response.stream)

        last_seq = -1
        # Seed from the seq-indexed view: buffered rows while the job is
        # live, the blob (as one synthetic chunk) once rows are purged.
        @job.log_chunk_list.each do |c|
          sse.write({ seq: c[:seq], chunk: c[:chunk] }.to_json, event: "chunk")
          last_seq = c[:seq]
        end

        # A job that hasn't started has no output coming; end now rather than
        # hold a thread, and let the page ask again shortly.
        return sse.write({ status: @job.status }.to_json, event: "waiting") if @job.pending? || @job.queued?

        deadline = stream_timeout.from_now
        loop do
          # Check a connection out per poll, not for the whole stream.
          done = ActiveRecord::Base.connection_pool.with_connection do
            job = JobRun.find(@job.id)
            job.log_chunks.where("seq > ?", last_seq).order(:seq).each do |c|
              sse.write({ seq: c.seq, chunk: c.chunk }.to_json, event: "chunk")
              last_seq = c.seq
            end
            sse.write({ status: job.status }.to_json, event: "done") if job.terminal?
            job.terminal?
          end
          break if done || Time.current >= deadline

          sleep 2
        end
      rescue IOError, ActionController::Live::ClientDisconnected
        # Client disconnected; nothing to clean up.
      ensure
        sse&.close
      end

      private

      def find_job_or_404
        @job = JobRun.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "job not found" }, status: :not_found
      end

      def with_owned_job_lock
        @job = JobRun.find(params[:id])
        @job.with_lock do
          require_job_owner!(@job)
          yield unless performed?
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "job not found" }, status: :not_found
      end

      # Reads accept the owning runner, a UI session, or API credentials.
      def authenticate_stream!
        return if performed?
        return if runner_token_owns_job? || valid_ui_session?

        if RunnerToken.authenticate(bearer_token)
          return render json: { error: "forbidden: job is owned by another token" }, status: :forbidden
        end

        authenticate_api!
      end

      def runner_token_owns_job?
        token = RunnerToken.authenticate(bearer_token)
        token.present? && @job.claimed_by == token.name
      end

      # The web UI's cookie session (same-origin EventSource/fetch send it).
      def valid_ui_session?
        SessionAuth.user_for(request.session).present?
      end
    end
  end
end
