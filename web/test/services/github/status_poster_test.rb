# frozen_string_literal: true

require "test_helper"

# End-to-end commit-status flow. NOT transactional: the Pipeline
# after_update_commit callback that posts terminal statuses only fires on
# real commits. Cleanup is scoped to this test's rows so parallel test
# processes are unaffected.
class GithubStatusPosterTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  class FakeClient
    attr_reader :statuses

    def initialize
      @statuses = []
    end

    def fetch_config(_full_name, _sha)
      nil
    end

    def create_commit_status(full_name, sha, state:, description:, target_url: nil, context: "forge-ci")
      @statuses << { full_name: full_name, sha: sha, state: state,
                     description: description, target_url: target_url, context: context }
      { "id" => 1 }
    end
  end

  setup do
    @old_host = ENV["APP_HOST"]
    ENV["APP_HOST"] = "https://ci.example.com"
    @client = FakeClient.new
    @old_factory = Github.client_factory
    fake = @client
    Github.client_factory = ->(_id) { fake }
    @installation = GithubInstallation.create!(installation_id: 4242, account_login: "octo")
    @project = Project.create!(name: "octo/status-test")
    @repo = @installation.github_repositories.create!(full_name: "octo/status-test", project: @project)
    @pipeline_ids = []
  end

  teardown do
    ENV["APP_HOST"] = @old_host
    Github.client_factory = @old_factory
    Pipeline.where(id: @pipeline_ids).destroy_all if defined?(@pipeline_ids)
    @repo.destroy
    @project.destroy
    @installation.destroy
  end

  def create_pipeline(sha: "statussha")
    yaml = file_fixture("ci_config.yml").read
    ir, errors = ForgeCI::Compiler.compile(yaml)
    assert_empty errors
    pipeline = PipelineIntake.call!(
      project: @project, sha: sha, branch: "main",
      ir: JSON.parse(ir.to_json), github_repository: @repo
    )
    @pipeline_ids << pipeline.id
    pipeline
  end

  def drive_all_jobs(pipeline, status)
    until pipeline.reload.job_runs.all?(&:terminal?)
      pipeline.job_runs.where(status: %w[pending queued]).each do |job|
        job.mark_queued! if job.pending?
        job.mark_claimed!(claimed_by: "test")
        job.mark_running!
        job.complete_with_results!(status: status)
      end
    end
    pipeline.reload
  end

  test "successful pipeline posts pending then success with target_url" do
    pipeline = create_pipeline
    Github::StatusPoster.post_pending(pipeline)
    drive_all_jobs(pipeline, "success")

    assert_equal "success", Pipeline.find(@pipeline_ids.last).status
    states = @client.statuses.map { |s| s[:state] }
    assert_equal %w[pending success], states
    success = @client.statuses.last
    assert_equal "forge-ci", success[:context]
    assert_equal "statussha", success[:sha]
    assert_equal "https://ci.example.com/projects/#{@project.id}/pipelines/#{@pipeline_ids.last}",
                 success[:target_url]
  end

  test "failed pipeline posts failure" do
    pipeline = create_pipeline
    Github::StatusPoster.post_pending(pipeline)
    drive_all_jobs(pipeline, "failed")

    assert_equal "failed", Pipeline.find(@pipeline_ids.last).status
    assert_equal %w[pending failure], @client.statuses.map { |s| s[:state] }
  end

  test "pipeline without a GitHub repo posts nothing" do
    yaml = file_fixture("ci_config.yml").read
    ir, _ = ForgeCI::Compiler.compile(yaml)
    pipeline = PipelineIntake.call!(
      project: @project, sha: "plainsha", branch: "main", ir: JSON.parse(ir.to_json)
    )
    @pipeline_ids << pipeline.id
    drive_all_jobs(pipeline, "success")
    assert_equal "success", pipeline.reload.status

    assert_empty @client.statuses
  end
end
