# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module ForgeCIRunner
  # Cache save/restore against the control plane's cache API:
  #
  #   PUT /api/v1/projects/:id/cache            (multipart: key, file)
  #   GET /api/v1/projects/:id/cache?keys[]=k   (server: exact match, then
  #                                             longest-prefix fallback)
  #
  # The runner resolves {{ }} key templates (see KeyTemplate) and moves
  # tarballs between the job container and the server; tar/untar happen
  # inside the container via the Executor's docker helpers, so this class
  # only ever sees host-side tarball paths.
  class CacheStore
    def initialize(client, project_id)
      @client = client
      @project_id = project_id
    end

    # Uploads the tarball at +tarball_path+ under +key+.
    # Returns the server's { "key", "size" } hash.
    def save(key, tarball_path)
      raise ArgumentError, "cache key is empty" if key.to_s.empty?
      raise ArgumentError, "tarball missing: #{tarball_path}" unless File.file?(tarball_path)

      @client.put_cache(@project_id, key, tarball_path)
    end

    # Tries each key in order (server-side fallback). Returns the local
    # path of the downloaded tarball, or nil on a clean miss (404).
    # The caller owns the returned file (and its temp dir): delete it
    # when done.
    def restore(keys)
      keys = Array(keys).map(&:to_s).reject(&:empty?)
      return nil if keys.empty?

      hit = @client.get_cache(@project_id, keys)
      return nil if hit.nil? || hit["download_url"].to_s.empty?

      dir = Dir.mktmpdir("forge-ci-cache")
      dest = File.join(dir, "cache.tgz")
      @client.download(hit["download_url"], dest)
      dest
    end
  end
end
