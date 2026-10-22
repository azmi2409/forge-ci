# frozen_string_literal: true

require "test_helper"

class Github::SyncPipelineJobTest < ActiveJob::TestCase
  # Stands in for Github::AppClient — no network. Records commit statuses.
  class FakeClient
    attr_reader :statuses

    def initialize(yaml:)
      @yaml = yaml
      @statuses = []
    end

    def fetch_config(_full_name, _sha)
      @yaml
    end

    def create_commit_status(full_name, sha, state:, description:, target_url: nil, context: "forge-ci")
      @statuses << { full_name: full_name, sha: sha, state: state,
                     description: description, target_url: target_url, context: context }
      { "id" => 1 }
    end
  end

  BAD_YAML = <<~YAML # missing docker executor -> compile error
    version: 2.1
    jobs:
      build:
        steps:
          - run: echo hi
    workflows:
      w:
        jobs: [build]
  YAML

  setup do
    @yaml = file_fixture("ci_config.yml").read
    @old_factory = Github.client_factory
    use_fake_client(FakeClient.new(yaml: @yaml))
  end

  teardown do
    Github.client_factory = @old_factory
  end

  def use_fake_client(client)
    @client = client
    Github.client_factory = ->(_id) { client }
  end

  def perform_with_fake(**kwargs)
    Github::SyncPipelineJob.perform_now(**kwargs)
  end

  def base_args(overrides = {})
    { installation_id: 42, account_login: "octo", repo_full_name: "octo/hello",
      sha: "abc123", branch: "main", forked: false }.merge(overrides)
  end

  def project_for(full_name = "octo/hello")
    GithubRepository.find_by!(full_name: full_name).project
  end

  test "push creates installation, project mapping, pipeline, and posts pending status" do
    perform_with_fake(**base_args)

    inst = GithubInstallation.find_by(installation_id: 42)
    assert_equal "octo", inst.account_login

    repo = GithubRepository.find_by(full_name: "octo/hello")
    assert_equal "octo/hello", repo.project.name
    assert_equal inst, repo.github_installation

    pipeline = Pipeline.last
    assert_equal "abc123", pipeline.sha
    assert_equal "main", pipeline.branch
    assert_equal "running", pipeline.status
    assert_equal 1, pipeline.pipeline_number
    assert_equal repo, pipeline.github_repository
    assert_not pipeline.forked
    assert_equal 3, pipeline.job_runs.count
    assert_equal %w[pending pending queued].sort, pipeline.job_runs.map(&:status).sort

    pending = @client.statuses.find { |s| s[:state] == "pending" }
    assert pending, "expected a pending commit status, got #{@client.statuses.inspect}"
    assert_equal "forge-ci", pending[:context]
    assert_equal "abc123", pending[:sha]
    assert_equal "octo/hello", pending[:full_name]
  end

  test "push to an already-mapped repo reuses the project and increments pipeline number" do
    perform_with_fake(**base_args)
    perform_with_fake(**base_args.merge(sha: "def456"))

    assert_equal 1, Project.where(name: "octo/hello").count
    assert_equal [1, 2], Pipeline.order(:pipeline_number).pluck(:pipeline_number)
  end

  test "pipeline number increments and is available to the config as pipeline.number" do
    perform_with_fake(**base_args)
    perform_with_fake(**base_args.merge(sha: "def456"))
    assert_equal [1, 2], Pipeline.order(:pipeline_number).pluck(:pipeline_number)
  end

  test "push and pull_request events for the same commit build it once" do
    perform_with_fake(**base_args(branch: "feature"))                # push
    perform_with_fake(**base_args(branch: "feature"))                # pull_request synchronize
    assert_equal 1, Pipeline.where(sha: "abc123").count
    assert_equal 1, @client.statuses.count { |st| st[:state] == "pending" }
  end

  test "repo without .circleci/config.yml is skipped silently (no pipeline, no status)" do
    use_fake_client(FakeClient.new(yaml: nil))
    perform_with_fake(**base_args)

    assert_equal 0, Pipeline.count
    assert_empty @client.statuses
  end

  test "fork pull request is marked forked and receives no contexts" do
    perform_with_fake(**base_args)
    project_for.contexts.create!(name: "deploy", payload: { "DEPLOY_KEY" => "s3cr3t" })

    perform_with_fake(**base_args.merge(sha: "forksha1", forked: true))

    pipeline = Pipeline.order(:created_at).last
    assert pipeline.forked, "expected forked=true"
    pipeline.job_runs.each do |job|
      assert job.context_environment.blank?,
             "forked pipeline must not receive contexts, got #{job.context_environment.inspect}"
    end
  end

  test "non-fork pipeline injects the project's default contexts" do
    perform_with_fake(**base_args)
    project_for.contexts.create!(name: "deploy", payload: { "DEPLOY_KEY" => "s3cr3t" })

    perform_with_fake(**base_args.merge(sha: "def456"))

    pipeline = Pipeline.order(:created_at).last
    assert_not pipeline.forked
    assert_equal({ "DEPLOY_KEY" => "s3cr3t" }, pipeline.job_runs.first.context_environment)
  end

  test "compile error creates a failed pipeline and posts a failure status with the error" do
    use_fake_client(FakeClient.new(yaml: BAD_YAML))
    perform_with_fake(**base_args)

    pipeline = Pipeline.last
    assert_equal "failed", pipeline.status
    assert_equal 0, pipeline.job_runs.count

    failure = @client.statuses.find { |s| s[:state] == "failure" }
    assert failure, "expected a failure commit status, got #{@client.statuses.inspect}"
    assert_includes failure[:description], "docker"
    assert_equal "forge-ci", failure[:context]
  end
end
