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
    job.with_lock do
      return unless job.terminal? && job.updated_at == version
      return unless job.log_chunks.order(:seq).pluck(:id, :chunk) == chunks.map { |c| [c.id, c.chunk] }

      job.log_blob.attach(blob)
      verify!(blob, text)
      job.log_chunks.where("seq <= ?", chunks.last.seq).delete_all
    end
  end

  private

  def upload(text, job_id)
    ActiveStorage::Blob.create_and_upload!(io: StringIO.new(text), filename: "job-#{job_id}.log", content_type: "text/plain")
  rescue StandardError => error
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
