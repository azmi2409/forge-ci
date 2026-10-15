# frozen_string_literal: true

module Api
  module V1
    # Log streaming (component 6).
    #
    # Chunk ingest and reads accept the owning runner's Bearer token. The
    # SSE live-tail (`stream`) and the plain `logs` read additionally accept
    # the UI's HTTP basic credentials, so the job page can tail logs without
    # holding a runner token (browsers resend basic-auth on same-origin
    # requests, but cannot set an Authorization: Bearer header on
    # EventSource).
    class JobsController < BaseController
      include ActionController::Live

      # How long a live-tail stream stays open waiting for new output.
      # Env-overridable (seconds) so proxies with their own idle timeouts
      # (e.g. 55s on Heroku) and the test suite can shorten it.
      def stream_timeout
        ENV.fetch("FORGE_CI_STREAM_TIMEOUT_SECONDS", "300").to_i.seconds
      end

      before_action :find_job_or_404, only: %i[stream]
      before_action :authenticate_stream!, only: %i[stream]
      before_action :find_owned_job, except: %i[stream]

      # `stream` has its own dual auth (Bearer token OR UI basic auth);
      # skip the base class's Bearer-only check for it.
      skip_before_action :authenticate_runner!, only: %i[stream]

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
      # Reads from the blob once the job is terminal (rows purged by then);
      # otherwise from the buffered rows. Simple polling is the fallback
      # live-tail story.
      def logs
        render json: { job_id: @job.id, chunks: @job.log_chunk_list }, status: :ok
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

        deadline = stream_timeout.from_now
        ActiveRecord::Base.connection_pool.with_connection do
          loop do
            job = JobRun.find(@job.id)
            job.log_chunks.where("seq > ?", last_seq).order(:seq).each do |c|
              sse.write({ seq: c.seq, chunk: c.chunk }.to_json, event: "chunk")
              last_seq = c.seq
            end
            if job.terminal?
              sse.write({ status: job.status }.to_json, event: "done")
              break
            end
            break if Time.current >= deadline

            sleep 2
          end
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

      def find_owned_job
        @job = JobRun.find(params[:id])
        require_job_owner!(@job)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "job not found" }, status: :not_found
      end

      # The stream is browser-facing: accept the owning runner token OR the
      # UI's basic-auth credentials.
      def authenticate_stream!
        return if performed?
        return if runner_token_owns_job? || valid_ui_basic_auth?

        render json: { error: "unauthorized" }, status: :unauthorized
      end

      def runner_token_owns_job?
        token = RunnerToken.authenticate(bearer_token)
        token.present? && @job.claimed_by == token.name
      end

      # Mirror of the UI's basic auth (see ApplicationController). Browsers
      # resend these credentials on same-origin EventSource requests.
      def valid_ui_basic_auth?
        header = request.headers["Authorization"].to_s
        scheme, _, credentials = header.partition(" ")
        return false unless scheme.casecmp("basic").zero?

        user, password = Base64.decode64(credentials.to_s).split(":", 2)
        expected_user = ENV["FORGE_CI_UI_USER"]
        expected_password = ENV["FORGE_CI_UI_PASSWORD"]
        if expected_user.blank? || expected_password.blank?
          return false if Rails.env.production?

          expected_user, expected_password = "admin", "password"
        end
        ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_user) &
          ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
      rescue ArgumentError
        false
      end
    end
  end
end
