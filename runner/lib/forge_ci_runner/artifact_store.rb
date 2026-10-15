# frozen_string_literal: true

module ForgeCIRunner
  # Artifact uploads against the control plane:
  #
  #   POST /api/v1/jobs/:id/artifacts   (multipart: file, path, destination?)
  #
  # Returns the server's hash ({ "id", "path", "destination", "size",
  # "download_url" }). The download_url has a 15-minute TTL and is only
  # logged, never stored.
  class ArtifactStore
    def initialize(client, job_id)
      @client = client
      @job_id = job_id
    end

    # Uploads one local file. +path+ is the display path shown in the UI
    # (defaults to the filename); +destination+ is the optional UI prefix.
    def upload(local_path, path: nil, destination: nil)
      raise ArgumentError, "artifact missing: #{local_path}" unless File.file?(local_path)

      @client.post_artifact(@job_id, local_path,
                            path: path || File.basename(local_path),
                            destination: destination)
    end
  end
end
