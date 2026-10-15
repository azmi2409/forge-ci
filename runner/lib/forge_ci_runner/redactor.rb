# frozen_string_literal: true

module ForgeCIRunner
  # Redacts secret values from log text before it leaves the runner.
  #
  # The claim payload merges executor env with context (secret) payloads
  # server-side, and the runner cannot tell which values are secrets. So v1
  # redacts *every* environment value at or above +min_length+ characters —
  # exact substring matches, longest values first (so "s3cr3t-value-long"
  # is redacted before its prefix "s3cr3t" could partially match).
  #
  # Short values (below min_length) are deliberately left alone: redacting
  # e.g. "test" or "true" would make logs unreadable, and real secrets are
  # long random strings. This is documented in the README; a future
  # contract version should have the server return an explicit secret key
  # list instead.
  class Redactor
    REPLACEMENT = "[REDACTED]"

    def initialize(environment, min_length: 8)
      @patterns = collect_patterns(environment, min_length)
    end

    def redact(text)
      return text if text.nil? || @patterns.empty?

      result = text.to_s
      @patterns.each { |pat| result = result.gsub(pat, REPLACEMENT) }
      result
    end

    # Exposed for tests / debugging (never log the values themselves).
    def pattern_count
      @patterns.length
    end

    private

    def collect_patterns(environment, min_length)
      pairs = case environment
              when Hash then environment.values
              when Array then environment.map { |e| e.is_a?(Array) ? e[1] : e }
              else []
              end
      pairs.map(&:to_s)
           .reject(&:empty?)
           .select { |v| v.length >= min_length }
           .uniq
           .sort_by { |v| -v.length }
    end
  end
end
