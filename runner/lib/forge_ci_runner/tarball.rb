# frozen_string_literal: true

require "open3"
require "fileutils"
require "tmpdir"

module ForgeCIRunner
  # Host-side tar.gz helpers (system `tar` via Open3 argv arrays, never a
  # shell). Container-side tarring goes through `docker exec` in the
  # Executor; this module handles host temp dirs (artifact packing,
  # workspace staging) and is fully unit-testable.
  module Tarball
    class Error < StandardError; end

    # Creates +dest+ (a .tgz) containing +paths+, interpreted relative to
    # +base_dir+. Missing paths are skipped with a warning; raises
    # Tarball::Error when nothing exists to archive.
    def self.create(paths, base_dir:, dest:, warn: ->(_m) {})
      existing = Array(paths).map(&:to_s).reject(&:empty?).select do |p|
        ok = File.exist?(File.join(base_dir, p))
        warn.call("tar: #{p.inspect} does not exist under #{base_dir}; skipping") unless ok
        ok
      end
      raise Error, "nothing to archive" if existing.empty?

      _out, status = Open3.capture2e("tar", "-czf", dest, "-C", base_dir, *existing)
      raise Error, "tar -czf failed (exit #{status.exitstatus})" unless status.success?

      dest
    end

    # Extracts a .tgz into +dest_dir+ (created if missing).
    def self.extract(tgz, dest_dir:)
      FileUtils.mkdir_p(dest_dir)
      _out, status = Open3.capture2e("tar", "-xzf", tgz, "-C", dest_dir)
      raise Error, "tar -xzf failed (exit #{status.exitstatus})" unless status.success?

      dest_dir
    end
  end
end
