# frozen_string_literal: true

require "test_helper"

class PipelinesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "acme/web", max_concurrency: 4)
    @pipeline = PipelineIntake.call!(project: @project, sha: "abc123", branch: "main", ir: compile_test_ir)
    sign_in_as("dev", role: :member)
  end

  test "a running pipeline offers cancel, not rerun" do
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_response :ok
    assert_select "form[action$='/cancel']"
    assert_select "form[action*='/rerun']", count: 0

    post "/projects/#{@project.id}/pipelines/#{@pipeline.id}/rerun"
    assert_redirected_to "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_match "Wait for the pipeline to finish", flash[:alert]
  end

  test "a canceled pipeline offers both reruns, and rerunning failed jobs queues them again" do
    @pipeline.cancel!
    get "/projects/#{@project.id}/pipelines/#{@pipeline.id}"
    assert_select "form[action*='/rerun?scope=failed']"
    assert_select "form[action*='/rerun?scope=all']"

    post "/projects/#{@project.id}/pipelines/#{@pipeline.id}/rerun", params: { scope: "failed" }
    assert_match "Rerunning 3 jobs that failed", flash[:notice]
    assert @pipeline.reload.running?
    assert_equal %w[pending pending queued], @pipeline.job_runs.map(&:status).sort
  end
end
