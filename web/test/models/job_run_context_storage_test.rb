# frozen_string_literal: true

require "test_helper"

class JobRunContextStorageTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(name: "encrypted-context-storage")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    workflow = pipeline.workflow_runs.create!(name: "build", status: "running")
    @job = workflow.job_runs.create!(name: "test", executor: { "type" => "docker" })
    @environment = { "DEPLOY_KEY" => "snapshot-secret-123", "UNICODE" => "秘密", "EMPTY" => "" }
  end

  test "context snapshot round trips without plaintext storage" do
    @job.update!(context_environment: @environment)

    assert_equal @environment, @job.reload.context_environment
    assert_equal @environment, @job.merged_environment
    raw = JobRun.connection.select_value(
      "SELECT encrypted_context_environment FROM job_runs WHERE id = #{@job.id.to_i}"
    )
    assert ActiveRecord::Encryption.encryptor.encrypted?(raw)
    @environment.each_value { |value| assert_not_includes raw, value unless value.empty? }
    assert_not_includes JobRun.column_names, "context_environment"
  end

  test "snapshot updates and in-place mutations stay encrypted" do
    @job.update!(context_environment: @environment)
    @job.reload.context_environment["DEPLOY_KEY"] = "rotated-secret-456"
    @job.save!

    assert_equal "rotated-secret-456", @job.reload.context_environment.fetch("DEPLOY_KEY")
    assert_equal @environment.except("DEPLOY_KEY"), @job.context_environment.except("DEPLOY_KEY")
    assert_not_includes @job.read_attribute_before_type_cast(:encrypted_context_environment), "rotated-secret-456"
  end

  test "nil and empty snapshots retain their behavior" do
    assert_nil @job.reload.context_environment
    @job.update!(context_environment: {})
    assert_equal({}, @job.reload.context_environment)
    @job.update!(context_environment: nil)
    assert_nil @job.reload.context_environment
    assert_equal({}, @job.merged_environment)
  end

  test "inspection and generic serialization omit context secrets even when requested" do
    @job.update!(context_environment: @environment)
    job = @job.reload

    assert_includes job.inspect, "[FILTERED]"
    assert_not_includes job.inspect, @environment.fetch("DEPLOY_KEY")
    [job.serializable_hash, job.as_json,
     job.serializable_hash(methods: %i[context_environment encrypted_context_environment])].each do |serialized|
      assert_not serialized.key?("context_environment")
      assert_not serialized.key?("encrypted_context_environment")
      assert_not_includes serialized.to_json, @environment.fetch("DEPLOY_KEY")
    end
  end

  test "plaintext in encrypted column fails closed" do
    raw = JobRun.connection.quote(JSON.dump(@environment))
    JobRun.connection.execute(
      "UPDATE job_runs SET encrypted_context_environment = #{raw} WHERE id = #{@job.id.to_i}"
    )

    assert_raises(ActiveRecord::Encryption::Errors::Decryption) { @job.reload.context_environment }
  end
end
