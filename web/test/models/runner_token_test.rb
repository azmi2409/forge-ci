# frozen_string_literal: true

require "test_helper"

class RunnerTokenTest < ActiveSupport::TestCase
  test "generate! returns record and raw token; only the digest is stored" do
    record, raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")

    assert record.persisted?
    assert_equal "runner-1", record.name
    assert_equal "medium", record.resource_class
    assert_equal 64, raw.length
    assert_not_equal raw, record.token_digest
    assert_equal Digest::SHA256.hexdigest(raw), record.token_digest
  end

  test "authenticate returns the record for a valid raw token" do
    record, raw = RunnerToken.generate!(name: "runner-1")
    assert_equal record, RunnerToken.authenticate(raw)
  end

  test "authenticate returns nil for wrong or blank tokens" do
    RunnerToken.generate!(name: "runner-1")
    assert_nil RunnerToken.authenticate("nope")
    assert_nil RunnerToken.authenticate("")
    assert_nil RunnerToken.authenticate(nil)
  end

  test "names are unique" do
    RunnerToken.generate!(name: "runner-1")
    assert_raises(ActiveRecord::RecordInvalid) { RunnerToken.generate!(name: "runner-1") }
  end

  test "authenticate accepts the static FORGE_CI_RUNNER_TOKEN secret and provisions a record" do
    secret = "s3cr3t-#{SecureRandom.hex(16)}"
    original = ENV["FORGE_CI_RUNNER_TOKEN"]
    ENV["FORGE_CI_RUNNER_TOKEN"] = secret
    begin
      record = RunnerToken.authenticate(secret)
      assert record.persisted?
      assert_equal "static-runner", record.name
      assert_nil record.resource_class
      # Second call returns the same record (no duplicates).
      assert_equal record.id, RunnerToken.authenticate(secret).id
      assert_equal 1, RunnerToken.where(name: "static-runner").count
    ensure
      ENV["FORGE_CI_RUNNER_TOKEN"] = original
    end
  end

  test "authenticate ignores the static secret when it does not match" do
    original = ENV["FORGE_CI_RUNNER_TOKEN"]
    ENV["FORGE_CI_RUNNER_TOKEN"] = "the-real-secret"
    begin
      assert_nil RunnerToken.authenticate("wrong-secret")
      assert_equal 0, RunnerToken.where(name: "static-runner").count
    ensure
      ENV["FORGE_CI_RUNNER_TOKEN"] = original
    end
  end

  test "generated tokens still authenticate when a static secret is set" do
    original = ENV["FORGE_CI_RUNNER_TOKEN"]
    ENV["FORGE_CI_RUNNER_TOKEN"] = "the-real-secret"
    begin
      record, raw = RunnerToken.generate!(name: "runner-1")
      assert_equal record, RunnerToken.authenticate(raw)
    ensure
      ENV["FORGE_CI_RUNNER_TOKEN"] = original
    end
  end
end
