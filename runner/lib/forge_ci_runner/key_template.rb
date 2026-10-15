# frozen_string_literal: true

require "digest"

module ForgeCIRunner
  # Resolves CircleCI-style `{{ }}` template functions in cache keys.
  # The compiler passes `{{ }}` through untouched, so the runner resolves
  # them at execution time:
  #
  #   {{ checksum "path/to/file" }}  SHA256 hex of the file's contents,
  #                                  relative to the job working directory.
  #                                  Missing/unreadable file -> "" (warned).
  #   {{ .Branch }}                  the pipeline branch
  #   {{ epoch }}                    current unix time (seconds)
  #
  # Anything else inside {{ }} is left as-is with a warning.
  #
  # Pure logic except for the injected +checksum+ callable, which keeps
  # Docker out of unit tests: production passes a callable that runs
  # `sha256sum` inside the job container.
  module KeyTemplate
    TEMPLATE_RE = /\{\{\s*(.+?)\s*\}\}/
    CHECKSUM_RE = /\Achecksum\s+"([^"]+)"\z/
    BRANCH_RE = /\A\.Branch\z/
    EPOCH_RE = /\Aepoch\z/

    # @param template [String] the raw key template
    # @param branch [String, nil] pipeline branch for {{ .Branch }}
    # @param checksum [#call] takes a relative path, returns hex string or nil
    # @param epoch [Integer, nil] override for {{ epoch }} (default: now)
    # @param warn [#call] receives warning strings
    # @return [String] the resolved key
    def self.resolve(template, branch:, checksum:, epoch: nil, warn: ->(_m) {})
      template.to_s.gsub(TEMPLATE_RE) do
        expr = Regexp.last_match(1).strip
        case expr
        when CHECKSUM_RE
          path = Regexp.last_match(1)
          hex = checksum.call(path)
          if hex.nil? || hex.empty?
            warn.call("checksum: #{path.inspect} is missing or unreadable; using empty string")
            ""
          else
            hex
          end
        when BRANCH_RE
          branch.to_s
        when EPOCH_RE
          (epoch || Time.now.to_i).to_s
        else
          warn.call("unknown template #{expr.inspect}; leaving as-is")
          "{{ #{expr} }}"
        end
      end
    end
  end
end
