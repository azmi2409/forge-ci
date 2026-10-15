# frozen_string_literal: true

module Api
  module V1
    # Log streaming over plain HTTP (v1 live-tail story is simple polling).
    class JobsController < BaseController
      before_action :find_owned_job

      # POST /api/v1/jobs/:id/log_chunks { seq:, chunk: }
      # Upsert on (job_run_id, seq) — safe to retry.
      def create_log_chunk
        seq = params[:seq]
        chunk = params[:chunk]
        unless seq.present? && chunk.present?
          return render json: { error: "seq and chunk are required" }, status: :unprocessable_entity
        end

        LogChunk.upsert(
          { job_run_id: @job.id, seq: seq.to_i, chunk: chunk.to_s,
            created_at: Time.current, updated_at: Time.current },
          unique_by: :index_log_chunks_on_job_run_id_and_seq
        )
        render json: { job_id: @job.id, seq: seq.to_i }, status: :ok
      end

      # GET /api/v1/jobs/:id/logs -> { chunks: [{seq, chunk}] } ordered by seq.
      def logs
        chunks = @job.log_chunks.order(:seq).map { |c| { seq: c.seq, chunk: c.chunk } }
        render json: { job_id: @job.id, chunks: chunks }, status: :ok
      end

      private

      def find_owned_job
        @job = JobRun.find(params[:id])
        require_job_owner!(@job)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "job not found" }, status: :not_found
      end
    end
  end
end
