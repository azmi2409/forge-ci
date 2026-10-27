# frozen_string_literal: true

module ForgeCIRunner
  # Redacts secret values from log text before it leaves the runner.
  #
  # The claim payload includes explicit +secret_values+ from project
  # variables and contexts. Those values are always redacted, even when
  # short. Other environment values are inferred by length because the
  # runner cannot know whether pipeline-config values are sensitive.
  # Patterns are exact substrings, longest first, so a longer value is
  # redacted before its prefix could partially match.
  class Redactor
    REPLACEMENT = "[REDACTED]"

    def initialize(environment, min_length: 8, secret_values: [])
      @patterns = collect_patterns(environment, min_length, secret_values)
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

    def collect_patterns(environment, min_length, secret_values)
      pairs = case environment
              when Hash then environment.values
              when Array then environment.map { |e| e.is_a?(Array) ? e[1] : e }
              else []
              end
      inferred = pairs.map(&:to_s).reject(&:empty?).select { |v| v.length >= min_length }
      explicit = Array(secret_values).map(&:to_s).reject(&:empty?)
      (inferred + explicit).uniq.sort_by { |v| -v.length }
    end
  end
end
