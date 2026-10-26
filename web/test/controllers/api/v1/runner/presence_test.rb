# frozen_string_literal: true

require "test_helper"

class Api::V1::Runner::PresenceTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "presence", max_concurrency: 4)
    @token, @raw = RunnerToken.generate!(name: "presence-token", resource_class: "medium")
    @uuid = SecureRandom.uuid
  end

  test "idle claims register and refresh one process with token class overriding requested class" do
    travel_to Time.current.change(usec: 0) do
      post claim_path, params: { resource_class: "forged" }, headers: identity, as: :json
      assert_response :unprocessable_entity
      instance = @token.runner_instances.sole
      assert_equal @uuid, instance.uuid
      assert_equal "medium", instance.resource_class
      assert_equal "ruby", instance.implementation
      assert_equal "idle", instance.status
      travel 30.seconds
      post claim_path, headers: identity
      assert_response :unprocessable_entity
      assert_equal Time.current, instance.reload.last_seen_at
      assert_equal 1, @token.runner_instances.count
    end
  end

  test "shared tokens keep process identities separate and UUID is token scoped" do
    [@uuid, SecureRandom.uuid].each do |uuid|
      post claim_path, headers: identity(uuid: uuid)
      assert_response :unprocessable_entity
    end
    other, raw = RunnerToken.generate!(name: "other-presence")
    post claim_path, headers: identity(raw: raw)
    assert_response :unprocessable_entity
    assert_equal 2, @token.runner_instances.count
    assert_equal @uuid, other.runner_instances.sole.uuid
  end

  test "classless idle runner records requested class and maximum hostname" do
    token, raw = RunnerToken.generate!(name: "classless-presence")
    post claim_path, params: { resource_class: "spot" },
         headers: identity(raw: raw).merge("X-Forge-Runner-Hostname" => "h" * 255), as: :json
    assert_response :unprocessable_entity
    assert_equal "spot", token.runner_instances.sole.resource_class
    assert_equal 255, token.runner_instances.sole.hostname.length
  end

  test "legacy requests remain unregistered and invalid identity never claims work" do
    pipeline = create_pipeline
    post claim_path, headers: bearer_headers(@raw)
    assert_response :ok
    assert_equal 0, RunnerInstance.count
    pipeline.job_runs.update_all(status: JobRun.statuses.fetch("queued"), claimed_by: nil)
    [
      { "X-Forge-Runner-ID" => "not-a-uuid" },
      { "X-Forge-Runner-ID" => "" },
      { "X-Forge-Runner-Hostname" => "x" * 256 },
      { "X-Forge-Runner-Hostname" => "" },
      { "X-Forge-Runner-Implementation" => "unknown" }
    ].each do |invalid|
      post claim_path, headers: identity.merge(invalid)
      assert_response :bad_request
      assert_equal 0, RunnerInstance.count
      assert_not pipeline.job_runs.where(status: :claimed).exists?
    end
    post claim_path, headers: identity.except("X-Forge-Runner-ID")
    assert_response :bad_request
    assert_equal 0, RunnerInstance.count
  end

  test "owned lifecycle updates presence and clears only matching assignment" do
    create_pipeline
    post claim_path, headers: identity
    assert_response :ok
    job = JobRun.find(json_body.fetch("id"))
    instance = @token.runner_instances.sole
    assert_equal job, instance.current_job_run
    assert_equal "busy", instance.status

    %w[start heartbeat].each do |action|
      travel 30.seconds do
        post "/api/v1/runner/jobs/#{job.id}/#{action}", headers: identity
        assert_response :ok
        assert_in_delta Time.current, instance.reload.last_seen_at, 1
        assert_equal job, instance.current_job_run
      end
    end

    newer = job.workflow_run.job_runs.create!(name: "newer", resource_class: "medium", status: :claimed, claimed_by: @token.name)
    instance.update!(current_job_run: newer)
    post "/api/v1/runner/jobs/#{job.id}/complete", params: { status: "success" }, headers: identity, as: :json
    assert_response :ok
    assert_equal newer, instance.reload.current_job_run
    post "/api/v1/runner/jobs/#{newer.id}/release", headers: identity
    assert_response :ok
    assert_nil instance.reload.current_job_run
    assert_equal "idle", instance.status

    post claim_path, headers: identity
    assert_response :ok
    post "/api/v1/runner/jobs/#{json_body.fetch('id')}/complete", params: { status: "success" }, headers: identity, as: :json
    assert_response :ok
    assert_nil instance.reload.current_job_run
  end

  test "another token cannot refresh presence through an owned job" do
    create_pipeline
    post claim_path, headers: identity
    job_id = json_body.fetch("id")
    other, raw = RunnerToken.generate!(name: "nonowner")
    %w[start heartbeat complete release].each do |action|
      post "/api/v1/runner/jobs/#{job_id}/#{action}", headers: identity(raw: raw)
      assert_response :forbidden
    end
    assert_empty other.runner_instances
  end

  private

  def claim_path
    "/api/v1/runner/jobs/claim"
  end

  def identity(uuid: @uuid, raw: @raw)
    bearer_headers(raw).merge("X-Forge-Runner-ID" => uuid, "X-Forge-Runner-Hostname" => "worker-1",
                              "X-Forge-Runner-Implementation" => "ruby")
  end

  def create_pipeline
    PipelineIntake.call!(project: @project, sha: "presence-sha", branch: "main", ir: compile_test_ir)
  end
end
