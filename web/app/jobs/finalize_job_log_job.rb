# frozen_string_literal: true

class FinalizeJobLogJob < ApplicationJob
  class StorageError < StandardError; end

  retry_on StorageError, wait: :polynomially_longer, attempts: 10

  def perform(job_id)
    job = JobRun.find_by(id: job_id)
    return unless job&.terminal?

    version = job.updated_at
    chunks = job.log_chunks.order(:seq).to_a
    return if chunks.empty?

    text = chunks.map(&:chunk).join
    blob = upload(text, job.id)
    verify!(blob, text)
    job.with_lock do
      return unless job.terminal? && job.updated_at == version
      unless job.log_chunks.order(:seq).pluck(:id, :chunk) == chunks.map { |c| [c.id, c.chunk] }
        raise StorageError, "log chunks changed during upload"
      end

      job.log_blob.attach(blob)
      job.log_chunks.where("seq <= ?", chunks.last.seq).delete_all
    end
    finalized = true
  ensure
    blob&.purge unless finalized
  end

  private

  def upload(text, job_id)
    io = StringIO.new(text)
    blob = ActiveStorage::Blob.create_after_unfurling!(io: io, filename: "job-#{job_id}.log", content_type: "text/plain")
    blob.upload_without_unfurling(io)
    blob
  rescue StandardError => error
    blob&.purge
    raise StorageError, error.message
  end

  def verify!(blob, text)
    unless blob.service.exist?(blob.key) && blob.byte_size == text.bytesize &&
           blob.checksum == Digest::MD5.base64digest(text) && blob.download == text.b
      raise StorageError, "log object verification failed"
    end
  rescue StandardError => error
    raise StorageError, error.message
  end
end
