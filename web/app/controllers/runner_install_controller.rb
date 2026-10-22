# frozen_string_literal: true

require "rubygems/package"
require "zlib"

# Public endpoints behind the one-line runner install on the Runners page:
#   GET /install-runner   the install script, with this control plane's URL
#   GET /runner.tar.gz    the runner code (bin/ and lib/) this server ships
# Neither holds a secret: the token is passed on the admin's command line.
class RunnerInstallController < ActionController::Base
  RUNNER_DIRS = %w[bin lib aws].freeze

  def script
    @base_url = control_plane_url
    render formats: :text, content_type: "text/x-shellscript"
  end

  def tarball
    send_data self.class.tarball, filename: "forge-ci-runner.tar.gz", type: "application/gzip"
  end

  # Built once per process: the runner code doesn't change while it runs.
  def self.tarball
    @tarball ||= build_tarball(runner_path)
  end

  def self.runner_path
    ENV["FORGE_CI_RUNNER_PATH"].presence || Rails.root.join("..", "runner").expand_path.to_s
  end

  def self.build_tarball(root)
    io = StringIO.new("".b)
    gz = Zlib::GzipWriter.new(io)
    Gem::Package::TarWriter.new(gz) do |tar|
      RUNNER_DIRS.each do |dir|
        Dir.glob(File.join(root, dir, "**", "*")).sort.each do |path|
          rel = path.delete_prefix("#{root}/")
          mode = File.stat(path).mode & 0o777
          if File.directory?(path)
            tar.mkdir(rel, mode)
          else
            tar.add_file_simple(rel, mode, File.size(path)) { |f| f.write(File.binread(path)) }
          end
        end
      end
    end
    gz.close
    io.string
  end

  private

  def control_plane_url
    (Github.app_host.presence || request.base_url).sub(%r{/+\z}, "")
  end
end
