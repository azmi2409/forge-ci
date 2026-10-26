# frozen_string_literal: true

require "test_helper"

class RedactorTest < Minitest::Test
  def test_redacts_long_values
    r = ForgeCIRunner::Redactor.new({ "DEPLOY_KEY" => "s3cr3t-value-12345" })
    assert_equal "token=[REDACTED] done",
                 r.redact("token=s3cr3t-value-12345 done")
  end

  def test_leaves_short_values_alone
    r = ForgeCIRunner::Redactor.new({ "RAILS_ENV" => "test" }, min_length: 8)
    assert_equal "RAILS_ENV=test ok", r.redact("RAILS_ENV=test ok")
  end

  def test_redacts_explicit_short_secret_values
    r = ForgeCIRunner::Redactor.new({ "RAILS_ENV" => "test" }, min_length: 8,
                                    secret_values: ["s3cr3t"])
    assert_equal "RAILS_ENV=test token=[REDACTED]", r.redact("RAILS_ENV=test token=s3cr3t")
  end

  def test_longest_first_avoids_partial_matches
    r = ForgeCIRunner::Redactor.new({ "A" => "abcdefgh", "B" => "abcdefghij" },
                                    min_length: 8)
    assert_equal "[REDACTED]", r.redact("abcdefghij")
  end

  def test_non_string_values
    r = ForgeCIRunner::Redactor.new({ "PORT" => 5432, "BIG" => 123456789 })
    assert_equal "port [REDACTED]", r.redact("port 123456789")
    assert_equal "port 5432", r.redact("port 5432") # too short, untouched
  end

  def test_nil_and_empty_text
    r = ForgeCIRunner::Redactor.new({ "K" => "long-secret-value" })
    assert_nil r.redact(nil)
    assert_equal "", r.redact("")
  end

  def test_no_secrets_noop
    r = ForgeCIRunner::Redactor.new({})
    assert_equal 0, r.pattern_count
    assert_equal "plain text", r.redact("plain text")
  end

  def test_min_length_configurable
    r = ForgeCIRunner::Redactor.new({ "K" => "abcde" }, min_length: 5)
    assert_equal "[REDACTED]", r.redact("abcde")
  end
end
