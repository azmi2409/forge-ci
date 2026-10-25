# frozen_string_literal: true

require "rubygems/package"
require "zlib"
require "digest"
require "fileutils"
require "tmpdir"

# Public endpoints behind the one-line runner install on the Runners page:
#   GET /install-runner   the install script, with this control plane's URL
#   GET /runner.tar.gz    the runner code this server ships
# Neither holds a secret: the token is passed on the admin's command line.
#
# The archive is built once per content fingerprint to a file under tmp and
# streamed from disk (send_file): it now carries multi-architecture Go
# binaries (~15MB each), so holding it in memory per Rails process — as the
# first implementation did — is no longer acceptable.
class RunnerInstallController < ActionController::Base
  RUNNER_DIRS = %w[bin lib aws].freeze

  def script
    @base_url = control_plane_url
    render formats: :text, content_type: "text/x-shellscript"
  end

  def tarball
    send_file self.class.tarball_path,
              filename: "forge-ci-runner.tar.gz",
              type: "application/gzip"
  end

  def self.runner_path
    ENV["FORGE_CI_RUNNER_PATH"].presence || Rails.root.join("..", "runner").expand_path.to_s
  end

  # Path of the cached archive for the current content, building it if the
  # fingerprint changed or the file was cleaned up. The fingerprint covers
  # relative paths, sizes and mtimes, so an edit invalidates the cache.
  def self.tarball_path
    fingerprint = dir_fingerprint(runner_path)
    path = File.join(archive_dir, "forge-ci-runner-#{fingerprint}.tar.gz")
    build_tarball(runner_path, path) unless File.exist?(path)
    path
  end

  def self.archive_dir
    File.join(Dir.tmpdir, "forge-ci-runner-archives")
  end

  def self.dir_fingerprint(root)
    digest = Digest::SHA256.new
    RUNNER_DIRS.each do |dir|
      Dir.glob(File.join(root, dir, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
        next if File.directory?(path)

        rel = path.delete_prefix("#{root}/")
        stat = File.stat(path)
        digest.update("#{rel}:#{stat.size}:#{stat.mtime.to_i}\n")
      end
    end
    digest.hexdigest[0, 16]
  end

  # Streams the archive to disk; file contents are piped through in chunks,
  # never loaded whole (the Go binaries are far too big for that).
  def self.build_tarball(root, dest)
    FileUtils.mkdir_p(File.dirname(dest))
    tmp = "#{dest}.tmp.#{Process.pid}"
    File.open(tmp, "wb") do |file|
      gz = Zlib::GzipWriter.new(file)
      Gem::Package::TarWriter.new(gz) do |tar|
        RUNNER_DIRS.each do |dir|
          Dir.glob(File.join(root, dir, "**", "*")).sort.each do |path|
            rel = path.delete_prefix("#{root}/")
            mode = File.stat(path).mode & 0o777
            if File.directory?(path)
              tar.mkdir(rel, mode)
            else
              tar.add_file_simple(rel, mode, File.size(path)) do |f|
                IO.copy_stream(path, f)
              end
            end
          end
        end
      end
      gz.close
    end
    File.rename(tmp, dest)
  rescue StandardError
    File.delete(tmp) if File.exist?(tmp)
    raise
  end

  private

  def control_plane_url
    (Github.app_host.presence || request.base_url).sub(%r{/+\z}, "")
  end
end
