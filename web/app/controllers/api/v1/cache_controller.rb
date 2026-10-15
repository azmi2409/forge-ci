# frozen_string_literal: true

module Api
  module V1
    # Cache API (component 7). Tarballs land in ActiveStorage (disk or
    # S3-compatible, see config/storage.yml).
    #
    # Auth: the Bearer runner token must own a claimed/running job in the
    # project — cache access is tied to active work, not to any token.
    class CacheController < BaseController
      before_action :find_project

      # PUT /api/v1/projects/:id/cache — multipart form:
      #   key:  the cache key (required)
      #   file: the tarball (required)
      # Upserts on (project_id, key): re-saving a key replaces the blob.
      def upsert
        return render_forbidden unless cache_authorized?

        key = params[:key].to_s
        upload = params[:file]
        if key.blank? || !upload.respond_to?(:tempfile)
          return render json: { error: "key and file (multipart upload) are required" },
                        status: :unprocessable_entity
        end

        entry = @project.cache_entries.find_or_initialize_by(key: key)
        entry.file.attach(
          io: upload.tempfile,
          filename: "#{key}.tar",
          content_type: upload.content_type.to_s.presence || "application/octet-stream"
        )
        entry.size = entry.file.blob.byte_size
        entry.storage_key = entry.file.blob.key
        entry.save!
        render json: { key: entry.key, size: entry.size }, status: :ok
      end

      # GET /api/v1/projects/:id/cache?keys[]=k1&keys[]=k2
      # Tries keys in order (CircleCI restore_cache semantics): exact match
      # wins; otherwise the most recent entry whose key starts with the
      # requested key (prefix fallback). 404 when nothing matches.
      def show
        return render_forbidden unless cache_authorized?

        entry = CacheEntry.lookup(@project, params[:keys])
        return render json: { error: "no matching cache entry" }, status: :not_found unless entry&.file&.attached?

        render json: {
          key: entry.key,
          size: entry.size,
          download_url: entry.file.blob.url(expires_in: ArtifactsController::DOWNLOAD_URL_TTL)
        }, status: :ok
      end

      private

      def find_project
        @project = Project.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "project not found" }, status: :not_found
      end

      def cache_authorized?
        token = current_runner_token
        JobRun.joins(workflow_run: :pipeline)
              .where(pipelines: { project_id: @project.id },
                     claimed_by: token.name,
                     status: %w[claimed running])
              .exists?
      end

      def render_forbidden
        render json: { error: "forbidden: token has no active job in this project" }, status: :forbidden
      end
    end
  end
end
