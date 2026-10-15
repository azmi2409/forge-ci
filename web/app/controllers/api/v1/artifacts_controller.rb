# frozen_string_literal: true

module Api
  module V1
    # Artifact upload/download (component 7). Files land in ActiveStorage
    # (disk or S3-compatible, see config/storage.yml).
    #
    # Upload is Bearer-authed to the owning runner token. Download accepts
    # the owning token OR the UI's basic-auth credentials (same dual-auth
    # story as the log stream).
    class ArtifactsController < BaseController
      # Signed download URLs stay valid this long.
      DOWNLOAD_URL_TTL = 15.minutes

      skip_before_action :authenticate_runner!, only: %i[download]
      before_action :find_owned_job, only: %i[create]

      # POST /api/v1/jobs/:id/artifacts — multipart form:
      #   file:        the uploaded file (required)
      #   path:        the store_artifacts path (defaults to the filename)
      #   destination: optional destination prefix shown in the UI
      def create
        upload = params[:file]
        unless upload.respond_to?(:tempfile)
          return render json: { error: "file is required (multipart upload)" }, status: :unprocessable_entity
        end

        artifact = @job.artifacts.create!(
          path: params[:path].to_s.presence || upload.original_filename.to_s,
          destination: params[:destination].to_s.presence
        )
        artifact.file.attach(
          io: upload.tempfile,
          filename: upload.original_filename.to_s,
          content_type: upload.content_type.to_s.presence || "application/octet-stream"
        )
        artifact.update!(
          size: artifact.file.blob.byte_size,
          storage_key: artifact.file.blob.key
        )
        render json: artifact_json(artifact), status: :created
      end

      # GET /api/v1/artifacts/:id/download — 302 to a fresh signed blob URL.
      # The blob key itself is never a permanent address.
      def download
        artifact = Artifact.find(params[:id])
        return render json: { error: "unauthorized" }, status: :unauthorized unless can_download?(artifact)
        return render json: { error: "no file attached" }, status: :not_found unless artifact.file.attached?

        redirect_to artifact.file.blob.url(expires_in: DOWNLOAD_URL_TTL), allow_other_host: true
      rescue ActiveRecord::RecordNotFound
        render json: { error: "artifact not found" }, status: :not_found
      end

      private

      def find_owned_job
        @job = JobRun.find(params[:id])
        require_job_owner!(@job)
      rescue ActiveRecord::RecordNotFound
        render json: { error: "job not found" }, status: :not_found
      end

      def can_download?(artifact)
        token = RunnerToken.authenticate(bearer_token)
        (token.present? && artifact.job_run.claimed_by == token.name) || ui_basic_auth_valid?
      end

      # Same UI basic-auth mirror as Api::V1::JobsController#valid_ui_basic_auth?.
      def ui_basic_auth_valid?
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

      def artifact_json(artifact)
        {
          id: artifact.id,
          path: artifact.path,
          destination: artifact.destination,
          size: artifact.size,
          # Time-limited signed URL — do not store it; hit the download
          # endpoint for a fresh one.
          download_url: artifact.file.blob.url(expires_in: DOWNLOAD_URL_TTL)
        }
      end
    end
  end
end
