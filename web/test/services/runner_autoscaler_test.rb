# frozen_string_literal: true

require "test_helper"

class RunnerAutoscalerTest < ActiveSupport::TestCase
  # Records calls; answers describe_auto_scaling_groups from @desired.
  class FakeAsg
    Group = Struct.new(:desired_capacity)
    Reply = Struct.new(:auto_scaling_groups)
    attr_reader :sets

    def initialize(desired) = (@desired = desired; @sets = [])

    def describe_auto_scaling_groups(auto_scaling_group_names:)
      name = auto_scaling_group_names.first
      Reply.new(@desired.key?(name) ? [Group.new(@desired[name])] : [])
    end

    def set_desired_capacity(auto_scaling_group_name:, desired_capacity:, honor_cooldown:)
      @sets << [auto_scaling_group_name, desired_capacity, honor_cooldown]
      @desired[auto_scaling_group_name] = desired_capacity
    end
  end

  setup do
    project = Project.create!(name: "p", max_concurrency: 20)
    pipeline = project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    @wf = pipeline.workflow_runs.create!(name: "wf", status: "running")
    @n = 0
  end

  def job(resource_class, status)
    @n += 1
    @wf.job_runs.create!(name: "j#{@n}", executor: { "type" => "docker" }, resource_class: resource_class, status: status)
  end

  def scaler(spec, desired)
    asg = FakeAsg.new(desired)
    [RunnerAutoscaler.new(groups: RunnerAutoscaler.groups(spec), client: asg), asg]
  end

  test "parses the group spec with defaults" do
    groups = RunnerAutoscaler.groups("spot=ci-spot:4:2, deploy=ci-deploy")
    assert_equal %w[spot deploy], groups.map(&:resource_class)
    assert_equal [4, 1], groups.map(&:max)
    assert_equal [2, 1], groups.map(&:jobs_per_instance)
    assert_raises(RunnerAutoscaler::ConfigError) { RunnerAutoscaler.groups("spot") }
  end

  test "scales a group up from zero for queued jobs, capped at max" do
    6.times { job("spot", "queued") }
    job("deploy", "pending") # waiting on requires: not claimable yet
    autoscaler, asg = scaler("spot=ci-spot:4,deploy=ci-deploy:1", { "ci-spot" => 0, "ci-deploy" => 0 })
    assert_equal({ "ci-spot" => 4 }, autoscaler.call)
    assert_equal [["ci-spot", 4, false]], asg.sets
  end

  test "counts running jobs, packs jobs per instance and never scales down" do
    job("spot", "running")
    job("spot", "queued")
    job("spot", "queued")
    autoscaler, asg = scaler("spot=ci-spot:5:2", { "ci-spot" => 1 })
    assert_equal({ "ci-spot" => 2 }, autoscaler.call) # 3 jobs, 2 per instance

    autoscaler, asg = scaler("spot=ci-spot:5:2", { "ci-spot" => 3 })
    assert_empty autoscaler.call
    assert_empty asg.sets, "a group above what's needed is left for idle runners to shrink"
  end

  test "classless jobs count toward the first group only" do
    job(nil, "queued")
    autoscaler, asg = scaler("spot=ci-spot:2,deploy=ci-deploy:1", { "ci-spot" => 0, "ci-deploy" => 0 })
    autoscaler.call
    assert_equal [["ci-spot", 1, false]], asg.sets
  end

  test "a missing group is skipped" do
    job("spot", "queued")
    autoscaler, asg = scaler("spot=nope:2", {})
    assert_empty autoscaler.call
    assert_empty asg.sets
  end

  test "the scheduled job does nothing unless FORGE_CI_AUTOSCALE is set" do
    job("spot", "queued")
    old = ENV.delete("FORGE_CI_AUTOSCALE")
    RunnerAutoscaler.client_factory = -> { flunk "no AWS client when autoscaling is off" }
    ScaleRunnersJob.perform_now
  ensure
    RunnerAutoscaler.client_factory = nil
    ENV["FORGE_CI_AUTOSCALE"] = old if old
  end

  test "the scheduled job scales when configured and survives AWS errors" do
    job("spot", "queued")
    asg = FakeAsg.new({ "ci-spot" => 0 })
    ENV["FORGE_CI_AUTOSCALE"] = "spot=ci-spot:2"
    RunnerAutoscaler.client_factory = -> { asg }
    ScaleRunnersJob.perform_now
    assert_equal [["ci-spot", 1, false]], asg.sets

    RunnerAutoscaler.client_factory = -> { raise "AWS is down" }
    ScaleRunnersJob.perform_now # logs, does not raise
  ensure
    RunnerAutoscaler.client_factory = nil
    ENV.delete("FORGE_CI_AUTOSCALE")
  end
end
