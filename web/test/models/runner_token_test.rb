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
end
