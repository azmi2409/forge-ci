# frozen_string_literal: true

require "test_helper"
require "base64"

class BuildCacheConfigTest < ActiveSupport::TestCase
  # Answers get_authorization_token like Aws::ECR::Client, counting calls.
  class FakeEcr
    AuthData = Struct.new(:authorization_token, :expires_at)
    Reply = Struct.new(:authorization_data)
    attr_reader :calls

    def initialize(token: "AWS:ecr-secret-token", expires_at: Time.now + 12.hours)
      @token = token
      @expires_at = expires_at
      @calls = 0
    end

    def get_authorization_token
      @calls += 1
      Reply.new([AuthData.new(Base64.strict_encode64(@token), @expires_at)])
    end
  end

  setup do
    @project = Project.create!(name: "demo", max_concurrency: 4)
    @pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    @wf = @pipeline.workflow_runs.create!(name: "wf", status: "running")
    BuildCacheConfig.reset_ecr_token!
    @old_env = ENV.to_h.slice("FORGE_CI_BUILD_CACHE_REGISTRY",
                              "FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME",
                              "FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD")
    @old_factory = BuildCacheConfig.ecr_factory
  end

  teardown do
    BuildCacheConfig.reset_ecr_token!
    BuildCacheConfig.ecr_factory = @old_factory
    keys = %w[FORGE_CI_BUILD_CACHE_REGISTRY FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME
              FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD]
    keys.each { |k| @old_env.key?(k) ? ENV[k] = @old_env[k] : ENV.delete(k) }
  end

  def remote_docker_job(branch: "main", forked: false)
    @n ||= 0
    @n += 1
    @pipeline.update!(branch: branch, forked: forked)
    @wf.job_runs.create!(name: "build-#{@n}", executor: { "type" => "docker" },
                         resource_class: "medium", status: "queued",
                         steps: [{ "type" => "setup_remote_docker", "layer_caching" => true }])
  end

  def plain_job
    @wf.job_runs.create!(name: "test", executor: { "type" => "docker" },
                         resource_class: "medium", status: "queued",
                         steps: [{ "type" => "run", "command" => "rspec" }])
  end

  def with_registry(value)
    ENV["FORGE_CI_BUILD_CACHE_REGISTRY"] = value
  end

  test "no section without FORGE_CI_BUILD_CACHE_REGISTRY" do
    ENV.delete("FORGE_CI_BUILD_CACHE_REGISTRY")
    assert_nil BuildCacheConfig.for_job(remote_docker_job)
    assert_not BuildCacheConfig.configured?
  end

  test "static credentials and a per-project, per-branch ref for other registries" do
    with_registry("ghcr.io/acme/forge-ci-cache")
    ENV["FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME"] = "acme-bot"
    ENV["FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD"] = "ghp-registry-pass"
    section = BuildCacheConfig.for_job(remote_docker_job)
    assert_equal({ registry: "ghcr.io/acme/forge-ci-cache",
                   ref: "ghcr.io/acme/forge-ci-cache:p#{@project.id}-main",
                   username: "acme-bot",
                   password: "ghp-registry-pass" }, section)
    assert BuildCacheConfig.configured?
  end

  test "unauthenticated registries get a section without credentials" do
    with_registry("registry.internal:5000/forge-ci-cache")
    ENV.delete("FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME")
    section = BuildCacheConfig.for_job(remote_docker_job)
    assert_equal({ registry: "registry.internal:5000/forge-ci-cache",
                   ref: "registry.internal:5000/forge-ci-cache:p#{@project.id}-main" }, section)
  end

  test "branch names become docker tags" do
    with_registry("ghcr.io/acme/forge-ci-cache")
    section = BuildCacheConfig.for_job(remote_docker_job(branch: "Feat/New-UI"))
    assert_equal "p#{@project.id}-feat-new-ui", section[:ref].split(":").last
  end

  test "ECR registries mint a cached authorization token" do
    with_registry("123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache")
    fake = FakeEcr.new
    BuildCacheConfig.ecr_factory = ->(region) { @region = region; fake }

    first = BuildCacheConfig.for_job(remote_docker_job)
    assert_equal "ap-southeast-3", @region, "region comes from the registry host"
    assert_equal "AWS", first[:username]
    assert_equal "ecr-secret-token", first[:password]
    assert_equal 1, fake.calls

    BuildCacheConfig.for_job(plain_job) # no setup_remote_docker: no mint
    BuildCacheConfig.for_job(remote_docker_job) # cached: no second mint
    assert_equal 1, fake.calls
  end

  test "a failing ECR mint omits credentials instead of breaking the claim" do
    with_registry("123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache")
    BuildCacheConfig.ecr_factory = ->(_region) { raise "no IAM credentials" }

    section = BuildCacheConfig.for_job(remote_docker_job)
    assert_equal({ registry: "123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache",
                   ref: "123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache:p#{@project.id}-main" },
                 section)
  end

  test "fork pipelines and jobs without setup_remote_docker get no section" do
    with_registry("ghcr.io/acme/forge-ci-cache")
    assert_nil BuildCacheConfig.for_job(remote_docker_job(forked: true))
    assert_nil BuildCacheConfig.for_job(plain_job)
  end

  test "setup_remote_docker without docker_layer_caching gets no credentials" do
    with_registry("123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache")
    fake = FakeEcr.new
    BuildCacheConfig.ecr_factory = ->(_region) { fake }
    job = remote_docker_job
    job.update!(steps: [{ "type" => "setup_remote_docker" }])
    assert_nil BuildCacheConfig.for_job(job)
    assert_equal 0, fake.calls, "no token minted for a job that didn't opt in"
  end

  test "ECR tokens are cached per region" do
    fake = FakeEcr.new
    regions = []
    BuildCacheConfig.ecr_factory = ->(region) { regions << region; fake }
    with_registry("123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache")
    BuildCacheConfig.for_job(remote_docker_job)
    with_registry("123456789012.dkr.ecr.us-east-1.amazonaws.com/forge-ci-cache")
    BuildCacheConfig.for_job(remote_docker_job)
    assert_equal %w[ap-southeast-3 us-east-1], regions, "a new region mints its own token"
  end
end
