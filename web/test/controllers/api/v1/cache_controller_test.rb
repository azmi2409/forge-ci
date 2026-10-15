# frozen_string_literal: true

require "test_helper"

class Api::V1::CacheControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @token_record, @raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir }, as: :json
    assert_response :created
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(@raw)
    assert_response :ok
    @job_id = json_body["id"]
  end

  def auth
    bearer_headers(@raw)
  end

  def tarball
    fixture_file_upload("report.txt", "application/octet-stream")
  end

  test "upsert stores the tarball and show finds it by exact key" do
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-abc", file: tarball }, headers: auth
    assert_response :ok
    assert_equal "v1-deps-abc", json_body["key"]

    get "/api/v1/projects/#{@project.id}/cache", params: { keys: ["v1-deps-abc"] }, headers: auth
    assert_response :ok
    assert_equal "v1-deps-abc", json_body["key"]
    assert json_body["download_url"].present?
  end

  test "show tries keys in order: exact beats earlier prefix" do
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-aaa111", file: tarball }, headers: auth
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-bbb222", file: tarball }, headers: auth

    get "/api/v1/projects/#{@project.id}/cache",
        params: { keys: ["v1-deps-zzz999", "v1-deps-bbb222"] }, headers: auth
    assert_response :ok
    assert_equal "v1-deps-bbb222", json_body["key"]
  end

  test "show falls back to the most recent prefix match" do
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-old", file: tarball }, headers: auth
    CacheEntry.find_by!(key: "v1-deps-old").update!(created_at: 2.days.ago)
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-new", file: tarball }, headers: auth

    get "/api/v1/projects/#{@project.id}/cache", params: { keys: ["v1-deps-"] }, headers: auth
    assert_response :ok
    assert_equal "v1-deps-new", json_body["key"]
  end

  test "show returns 404 when nothing matches" do
    get "/api/v1/projects/#{@project.id}/cache", params: { keys: ["nope"] }, headers: auth
    assert_response :not_found
  end

  test "upsert replaces the blob when the key is saved again" do
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-abc", file: tarball }, headers: auth
    first_key = CacheEntry.find_by!(key: "v1-deps-abc").file.blob.key

    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "v1-deps-abc", file: tarball }, headers: auth
    assert_response :ok
    assert_equal 1, @project.cache_entries.where(key: "v1-deps-abc").count
    assert_not_equal first_key, CacheEntry.find_by!(key: "v1-deps-abc").file.blob.key
  end

  test "upsert requires key and file" do
    put "/api/v1/projects/#{@project.id}/cache", params: { key: "k" }, headers: auth
    assert_response :unprocessable_entity
  end

  test "cache endpoints reject a token with no active job in the project" do
    _rec, other_raw = RunnerToken.generate!(name: "runner-2", resource_class: "medium")
    put "/api/v1/projects/#{@project.id}/cache",
        params: { key: "k", file: tarball }, headers: bearer_headers(other_raw)
    assert_response :forbidden
    get "/api/v1/projects/#{@project.id}/cache", params: { keys: ["k"] },
        headers: bearer_headers(other_raw)
    assert_response :forbidden
  end

  test "cache endpoints require authentication" do
    put "/api/v1/projects/#{@project.id}/cache", params: { key: "k", file: tarball }
    assert_response :unauthorized
  end
end
