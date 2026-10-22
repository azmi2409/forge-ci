# frozen_string_literal: true

require "test_helper"

class JobLogChannelTest < ActionCable::Channel::TestCase
  setup do
    project = Project.create!(name: "p")
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
    @job = wf.job_runs.create!(name: "build", executor: { "type" => "docker" })
    stub_connection current_user: User.new(username: "dev")
  end

  test "subscribes to a job's log notices" do
    subscribe job_id: @job.id
    assert subscription.confirmed?
    assert_has_stream "job_log:#{@job.id}"
  end

  test "rejects an unknown job" do
    subscribe job_id: 0
    assert subscription.rejected?
  end
end

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  test "rejects a connection without a signed-in session" do
    assert_reject_connection { connect }
  end

  test "connects with the web UI's session cookie" do
    user = User.create!(username: "cable-user", password: "correct horse battery", role: :member)
    now = Time.current.to_i
    cookies.encrypted["_forge_ci_session"] = { value: { "user_id" => user.id, "nonce" => user.session_nonce,
                                                        "started_at" => now, "seen_at" => now } }
    connect
    assert_equal user, connection.current_user
  end
end
