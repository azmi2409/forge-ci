# frozen_string_literal: true

require "test_helper"

class Api::V1::QueueControllerTest < ActionDispatch::IntegrationTest
  setup do
    project = Project.create!(name: "q", max_concurrency: 8)
    wf = project.pipelines.create!(sha: "abc", branch: "main", status: "running").workflow_runs.create!(name: "wf", status: "running")
    [%w[spot queued], %w[spot queued], %w[spot running], ["deploy", "claimed"], [nil, "queued"], %w[spot success]].each_with_index do |(klass, status), i|
      wf.job_runs.create!(name: "j#{i}", executor: { "type" => "docker" }, resource_class: klass, status: status)
    end
  end

  test "requires the admin token" do
    get "/api/v1/queue"
    assert_includes [401, 403, 503], response.status
  end

  test "counts queued and in-flight jobs per resource class" do
    get "/api/v1/queue", headers: admin_headers
    assert_response :ok
    classes = json_body["resource_classes"]
    assert_equal({ "queued" => 2, "running" => 1 }, classes["spot"])
    assert_equal({ "queued" => 0, "running" => 1 }, classes["deploy"])
    assert_equal({ "queued" => 1, "running" => 0 }, classes["any"])
  end
end
