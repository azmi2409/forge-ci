# frozen_string_literal: true

require "test_helper"

class ProjectVariableTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "vars", max_concurrency: 2)
  end

  test "names must be valid environment variable names, unique per project" do
    assert @project.variables.create(name: "DATABASE_URL", value: "x").persisted?
    assert @project.variables.create(name: "_private1", value: "x").persisted?
    %w[1ABC A-B A\ B].each do |bad|
      assert_not @project.variables.build(name: bad, value: "x").valid?, "#{bad} should be rejected"
    end
    assert_not @project.variables.build(name: "DATABASE_URL", value: "y").valid?
    assert_not @project.variables.build(name: "EMPTY", value: "").valid?
  end

  test "the value is encrypted at rest, masked for display and filtered from inspect" do
    v = @project.variables.create!(name: "TOKEN", value: "supersecretvalue1234")
    raw = ProjectVariable.connection.select_value("SELECT value FROM project_variables WHERE id = #{v.id}")
    assert_not_includes raw, "supersecretvalue1234"
    assert_equal "supersecretvalue1234", v.reload.value
    assert_equal "••••1234", v.masked_value
    assert_equal "••••", @project.variables.build(name: "SHORT", value: "abc123").masked_value
    assert_not_includes v.inspect, "supersecret"
  end

  test "jobs get project variables below the config's environment and contexts; fork PRs get none" do
    @project.variables.create!(name: "RAILS_ENV", value: "from-project")
    @project.variables.create!(name: "ONLY_PROJECT", value: "p")
    @project.variables.create!(name: "SHARED", value: "from-project")
    @project.contexts.create!(name: "deploy", payload: { "SHARED" => "from-context" })

    pipeline = PipelineIntake.call!(project: @project, sha: "abc", branch: "main", ir: compile_test_ir, context_names: ["deploy"])
    env = pipeline.job_runs.find_by(name: "build").merged_environment
    assert_equal "p", env["ONLY_PROJECT"]
    assert_equal "test", env["RAILS_ENV"], "the job's own environment wins over project variables"
    assert_equal "from-context", env["SHARED"], "contexts win over project variables"

    @project.variables.find_by(name: "ONLY_PROJECT").update!(value: "changed")
    assert_equal "changed", pipeline.job_runs.find_by(name: "build").merged_environment["ONLY_PROJECT"],
                 "read at claim time, so queued jobs see the latest value"

    fork = PipelineIntake.call!(project: @project, sha: "def", branch: "pr", ir: compile_test_ir, forked: true)
    assert_nil fork.job_runs.find_by(name: "build").merged_environment["ONLY_PROJECT"]
  end
end
