# frozen_string_literal: true

require "test_helper"

class Api::V1::ArtifactsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @token_record, @raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir }, headers: admin_headers, as: :json
    assert_response :created
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(@raw)
    assert_response :ok
    @job_id = json_body["id"]
  end

  def auth
    bearer_headers(@raw)
  end

  def upload_fixture
    fixture_file_upload("report.txt", "text/plain")
  end

  test "upload attaches the file and returns a signed download URL" do
    post "/api/v1/jobs/#{@job_id}/artifacts",
         params: { file: upload_fixture, path: "reports/out.txt", destination: "reports" },
         headers: auth
    assert_response :created
    body = json_body
    assert_equal "reports/out.txt", body["path"]
    assert_equal "reports", body["destination"]
    assert body["size"].positive?
    assert body["download_url"].present?, "expected a signed download URL"

    artifact = Artifact.find(body["id"])
    assert artifact.file.attached?
    assert_equal "hello from the artifact\nsecond line\n", artifact.file.download
  end

  test "upload defaults path to the filename" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    assert_response :created
    assert_equal "report.txt", json_body["path"]
  end

  test "upload without a file is 422" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { path: "x" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "upload by a non-owning token is 403" do
    _rec, other_raw = RunnerToken.generate!(name: "runner-2", resource_class: "medium")
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture },
         headers: bearer_headers(other_raw)
    assert_response :forbidden
  end

  test "download redirects to a fresh signed URL" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    id = json_body["id"]

    get "/api/v1/artifacts/#{id}/download", headers: auth
    assert_response :redirect
    assert_match %r{/rails/active_storage/}, response.headers["Location"]
  end

  test "download accepts UI basic auth" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    id = json_body["id"]

    sign_in_as_admin
    get "/api/v1/artifacts/#{id}/download"
    assert_response :redirect
  end

  test "download rejects unauthenticated requests" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    id = json_body["id"]

    get "/api/v1/artifacts/#{id}/download"
    assert_response :unauthorized
  end

  test "retention job purges old artifacts and their blobs" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    artifact = Artifact.find(json_body["id"])
    blob_key = artifact.file.blob.key
    artifact.update!(created_at: 60.days.ago)

    assert_difference("Artifact.count", -1) do
      PurgeOldArtifactsJob.perform_now
    end
    assert_not ActiveStorage::Blob.exists?(key: blob_key), "blob should be purged from storage"
  end

  test "retention job keeps recent artifacts" do
    post "/api/v1/jobs/#{@job_id}/artifacts", params: { file: upload_fixture }, headers: auth
    assert_no_difference("Artifact.count") do
      PurgeOldArtifactsJob.perform_now
    end
  end
end
