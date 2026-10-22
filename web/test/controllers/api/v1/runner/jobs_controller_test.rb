# frozen_string_literal: true

require "test_helper"

class Api::V1::Runner::JobsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @project.contexts.create!(name: "deploy", payload: { "DEPLOY_KEY" => "s3cr3t", "SHARED" => "from-context" })
    @token_record, @raw = RunnerToken.generate!(name: "runner-1", resource_class: "medium")
    post "/api/v1/projects/#{@project.id}/pipelines",
         params: { sha: "abc123", branch: "main", ir: compile_test_ir, contexts: ["deploy"] }, headers: admin_headers, as: :json
    assert_response :created
    @pipeline = Pipeline.find(json_body["id"])
  end

  def auth
    bearer_headers(@raw)
  end

  def job_named(name)
    @pipeline.job_runs.find_by!(name: name)
  end

  # --- claim -------------------------------------------------------------------

  test "claim returns the oldest queued job with the full payload" do
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    body = json_body

    assert_equal "build", body["name"]
    assert_equal "~/project", body["working_directory"]
    assert_equal "cimg/ruby:3.2", body["executor"]["image"]
    assert_equal "medium", body["executor"]["resource_class"]
    assert_equal 2, body["steps"].size
    assert_equal "abc123", body["pipeline"]["sha"]
    assert_equal "main", body["pipeline"]["branch"]
    assert_equal @pipeline.workflow_runs.sole.id, body["workflow_run_id"]

    # environment: executor env merged with context payloads, contexts win
    assert_equal "test", body["environment"]["RAILS_ENV"]
    assert_equal "s3cr3t", body["environment"]["DEPLOY_KEY"]

    # raw context records are never exposed
    assert_not body.key?("contexts")
    assert_not body.key?("context")

    job = job_named("build").reload
    assert job.claimed?
    assert_equal "runner-1", job.claimed_by
    assert_not_nil job.claimed_at
    assert_not_nil job.heartbeat_at
  end

  test "claim returns 422 when nothing is claimable" do
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok # first claim took build
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :unprocessable_entity # test/deploy are still pending
  end

  test "token cannot claim a job of another resource class" do
    _rec, small_raw = RunnerToken.generate!(name: "small-runner", resource_class: "small")
    post "/api/v1/runner/jobs/claim", headers: bearer_headers(small_raw)
    assert_response :unprocessable_entity, "small token must not claim the medium build job"
  end

  test "claim honors the project's max_concurrency cap" do
    @project.update!(max_concurrency: 1)
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    # complete build -> test becomes queued, but the slot is still occupied
    # (claimed). Reclaim the heartbeat first to simulate the slot freeing...
    job = job_named("build").reload
    job.update_columns(heartbeat_at: 5.minutes.ago)
    JobRun.reclaim_stale!
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok, "freed slot allows the next claim"
  end

  test "claim with a full project returns 422 even when jobs are queued" do
    @project.update!(max_concurrency: 1)
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    # occupy the single slot with a running job, then queue another manually
    job_named("build").reload.mark_running!
    extra = @pipeline.workflow_runs.sole.job_runs.create!(
      name: "extra", executor: { "type" => "docker" }, resource_class: "medium",
      status: "queued", steps: []
    )
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :unprocessable_entity, "cap of 1 with 1 active job must block the claim"
    assert extra.reload.queued?
  end

  # --- auth --------------------------------------------------------------------

  test "missing or wrong bearer token returns 401" do
    post "/api/v1/runner/jobs/claim"
    assert_response :unauthorized
    post "/api/v1/runner/jobs/claim", headers: bearer_headers("bogus")
    assert_response :unauthorized
    post "/api/v1/runner/jobs/claim", headers: { "Authorization" => "Token abc" }
    assert_response :unauthorized
  end

  test "heartbeat by a token that did not claim the job returns 403" do
    post "/api/v1/runner/jobs/claim", headers: auth
    job_id = json_body["id"]
    _rec, other_raw = RunnerToken.generate!(name: "runner-2", resource_class: "medium")

    post "/api/v1/runner/jobs/#{job_id}/heartbeat", headers: bearer_headers(other_raw)
    assert_response :forbidden
  end

  # --- heartbeat / start ----------------------------------------------------------

  test "heartbeat refreshes heartbeat_at for the owning token" do
    post "/api/v1/runner/jobs/claim", headers: auth
    job_id = json_body["id"]
    job_named("build").reload.update_column(:heartbeat_at, 1.hour.ago)

    post "/api/v1/runner/jobs/#{job_id}/heartbeat", headers: auth
    assert_response :ok
    assert_in_delta Time.current.to_f, job_named("build").reload.heartbeat_at.to_f, 5
  end

  test "start moves claimed -> running" do
    post "/api/v1/runner/jobs/claim", headers: auth
    job_id = json_body["id"]

    post "/api/v1/runner/jobs/#{job_id}/start", headers: auth
    assert_response :ok
    assert_equal "running", json_body["status"]
    assert job_named("build").reload.running?
  end

  test "start on a non-claimed job returns 422" do
    job = job_named("build") # still queued, not claimed by anyone
    post "/api/v1/runner/jobs/#{job.id}/start", headers: auth
    assert_response :forbidden # not the owner (nobody claimed it)
  end

  # --- complete --------------------------------------------------------------------

  test "completing build unblocks test; completing test unblocks deploy" do
    post "/api/v1/runner/jobs/claim", headers: auth
    build_id = json_body["id"]

    post "/api/v1/runner/jobs/#{build_id}/start", headers: auth
    post "/api/v1/runner/jobs/#{build_id}/complete",
         params: { status: "success",
                   step_results: [{ name: "Install dependencies", exit_code: 0,
                                    started_at: Time.current - 60, finished_at: Time.current }] },
         headers: auth, as: :json
    assert_response :ok
    assert_equal "success", json_body["status"]

    build = job_named("build").reload
    assert build.success?
    step = build.step_runs.find_by!(name: "Install dependencies")
    assert step.success?
    assert_equal 0, step.exit_code

    assert job_named("test").reload.queued?, "test must be queued once build succeeds"
    assert job_named("deploy").reload.pending?, "deploy still waits on test"

    # claim + complete test -> deploy becomes queued
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_equal "test", json_body["name"]
    test_id = json_body["id"]
    post "/api/v1/runner/jobs/#{test_id}/complete", params: { status: "success" }, headers: auth, as: :json
    assert_response :ok
    assert job_named("deploy").reload.queued?

    # complete deploy -> workflow + pipeline succeed.
    # deploy needs resource_class "large", so a large runner claims it.
    _large_rec, large_raw = RunnerToken.generate!(name: "large-runner", resource_class: "large")
    large_auth = bearer_headers(large_raw)
    post "/api/v1/runner/jobs/claim", headers: large_auth
    assert_response :ok
    assert_equal "deploy", json_body["name"]
    deploy_id = json_body["id"]
    post "/api/v1/runner/jobs/#{deploy_id}/complete", params: { status: "success" }, headers: large_auth, as: :json
    assert_response :ok
    assert_equal "success", @pipeline.workflow_runs.sole.reload.status
    assert_equal "success", @pipeline.reload.status
  end

  test "failed job cancels its pending dependents and fails the workflow/pipeline" do
    post "/api/v1/runner/jobs/claim", headers: auth
    build_id = json_body["id"]
    post "/api/v1/runner/jobs/#{build_id}/complete", params: { status: "failed" }, headers: auth, as: :json
    assert_response :ok

    assert job_named("test").reload.canceled?, "dependents are canceled after a failure"
    assert job_named("deploy").reload.canceled?, "transitive dependents are canceled too"
    assert_equal "failed", @pipeline.workflow_runs.sole.reload.status
    assert_equal "failed", @pipeline.reload.status
  end

  test "complete with a non-terminal status returns 422" do
    post "/api/v1/runner/jobs/claim", headers: auth
    build_id = json_body["id"]
    post "/api/v1/runner/jobs/#{build_id}/complete", params: { status: "running" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "complete by a non-owning token returns 403" do
    post "/api/v1/runner/jobs/claim", headers: auth
    build_id = json_body["id"]
    _rec, other_raw = RunnerToken.generate!(name: "runner-2", resource_class: "medium")
    post "/api/v1/runner/jobs/#{build_id}/complete", params: { status: "success" },
         headers: bearer_headers(other_raw), as: :json
    assert_response :forbidden
  end

  # --- repository info (integration fix) --------------------------------------

  test "claim payload includes repository from the GitHub repo mapping" do
    inst = GithubInstallation.create!(installation_id: 99, account_login: "octo")
    inst.github_repositories.create!(full_name: "octo/hello", project: @project)
    @pipeline.update!(github_repository: inst.github_repositories.sole)

    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    repo = json_body["repository"]
    assert_equal "https://github.com/octo/hello.git", repo["url"]
    assert_equal "abc123", repo["sha"]
    assert_equal "main", repo["branch"]
  end

  test "claim payload carries a GitHub App installation token for checkout" do
    inst = GithubInstallation.create!(installation_id: 99, account_login: "octo")
    inst.github_repositories.create!(full_name: "octo/private", project: @project)
    @pipeline.update!(github_repository: inst.github_repositories.sole)
    requested = nil
    fake = Object.new
    fake.define_singleton_method(:installation_token) { "ghs_checkout_token" }
    with_github_app(->(id) { requested = id; fake }) do
      post "/api/v1/runner/jobs/claim", headers: auth
    end
    assert_response :ok
    repo = json_body["repository"]
    assert_equal 99, requested
    assert_equal "ghs_checkout_token", repo["token"]
    assert_equal "https://github.com/octo/private.git", repo["url"]
  end

  test "claim payload omits the token when GitHub refuses" do
    inst = GithubInstallation.create!(installation_id: 99, account_login: "octo")
    inst.github_repositories.create!(full_name: "octo/hello", project: @project)
    @pipeline.update!(github_repository: inst.github_repositories.sole)
    fake = Object.new
    fake.define_singleton_method(:installation_token) { raise Github::AppClient::ApiError.new(401, "bad") }
    with_github_app(->(_id) { fake }) do
      post "/api/v1/runner/jobs/claim", headers: auth
    end
    assert_response :ok
    assert_not json_body["repository"].key?("token")
    assert_equal "https://github.com/octo/hello.git", json_body["repository"]["url"]
  end

  test "claim payload falls back to project repo_url" do
    @project.update!(repo_url: "https://git.example.com/acme/app.git")

    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    repo = json_body["repository"]
    assert_equal "https://git.example.com/acme/app.git", repo["url"]
    assert_equal "abc123", repo["sha"]
  end

  test "claim payload omits repository when nothing is known (backward compatible)" do
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :ok
    assert_not json_body.key?("repository")
  end

  private

  def with_github_app(factory)
    old_factory = Github.client_factory
    old_env = ENV.to_h.slice("GITHUB_APP_ID", "GITHUB_APP_PRIVATE_KEY")
    ENV["GITHUB_APP_ID"] = "1"
    ENV["GITHUB_APP_PRIVATE_KEY"] = "pem"
    Github.client_factory = factory
    yield
  ensure
    Github.client_factory = old_factory
    %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY].each { |k| old_env.key?(k) ? ENV[k] = old_env[k] : ENV.delete(k) }
  end
end
