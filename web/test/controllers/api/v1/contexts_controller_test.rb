# frozen_string_literal: true

require "test_helper"

class Api::V1::ContextsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @context = @project.contexts.create!(name: "deploy", payload: { "DEPLOY_KEY" => "old-secret" })
    @admin = "test-admin-token-123"
  end

  def with_admin_token
    original = ENV["FORGE_CI_ADMIN_TOKEN"]
    ENV["FORGE_CI_ADMIN_TOKEN"] = @admin
    yield
  ensure
    ENV["FORGE_CI_ADMIN_TOKEN"] = original
  end

  def admin_headers
    { "Authorization" => "Bearer #{@admin}" }
  end

  test "rotate replaces the payload and never echoes values" do
    with_admin_token do
      post "/api/v1/contexts/#{@context.id}/rotate",
           params: { payload: { "DEPLOY_KEY" => "new-secret", "EXTRA" => "x" } },
           headers: admin_headers, as: :json
      assert_response :ok
      body = json_body
      assert_equal %w[DEPLOY_KEY EXTRA], body["keys"]
      assert_not body.to_s.include?("new-secret"), "secret values must never appear in responses"

      assert_equal({ "DEPLOY_KEY" => "new-secret", "EXTRA" => "x" }, @context.reload.payload)
    end
  end

  test "rotate rejects empty or blank-keyed payloads" do
    with_admin_token do
      post "/api/v1/contexts/#{@context.id}/rotate", params: { payload: {} },
           headers: admin_headers, as: :json
      assert_response :unprocessable_entity

      post "/api/v1/contexts/#{@context.id}/rotate", params: { payload: { "" => "x" } },
           headers: admin_headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "rotate requires the admin token" do
    with_admin_token do
      post "/api/v1/contexts/#{@context.id}/rotate",
           params: { payload: { "A" => "b" } }, as: :json
      assert_response :unauthorized

      _rec, raw = RunnerToken.generate!(name: "runner-1")
      post "/api/v1/contexts/#{@context.id}/rotate",
           params: { payload: { "A" => "b" } }, headers: bearer_headers(raw), as: :json
      assert_response :unauthorized
    end
  end

  test "rotate is fail-closed when the admin token is not configured" do
    ENV["FORGE_CI_ADMIN_TOKEN"] = nil
    post "/api/v1/contexts/#{@context.id}/rotate",
         params: { payload: { "A" => "b" } }, headers: admin_headers, as: :json
    assert_response :service_unavailable
  ensure
    ENV["FORGE_CI_ADMIN_TOKEN"] = nil
  end

  test "rotate on a missing context is 404" do
    with_admin_token do
      post "/api/v1/contexts/999999/rotate", params: { payload: { "A" => "b" } },
           headers: admin_headers, as: :json
      assert_response :not_found
    end
  end

  test "context payload is encrypted at rest and filtered from inspect" do
    raw = @context.encrypted_payload_before_type_cast
    assert_not_includes raw.to_s, "old-secret"
    assert_includes @context.inspect, "[FILTERED]"
    assert_not_includes @context.inspect, "old-secret"
  end

  test "claim payload exposes merged env but never raw context records" do
    _rec, raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc", branch: "main", ir: compile_test_ir, contexts: ["deploy"] }, as: :json
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(raw)
    body = json_body
    assert_equal "old-secret", body["environment"]["DEPLOY_KEY"]
    assert_not body.key?("contexts")
    assert_not body.key?("context")
    assert_not body.key?("payload")
  end
end
