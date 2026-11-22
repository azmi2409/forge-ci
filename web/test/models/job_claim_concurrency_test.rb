# frozen_string_literal: true

require "test_helper"
require "timeout"

class JobClaimConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "requires PostgreSQL row locks" unless JobRun.postgres?

    @projects = []
    @threads = []
  end

  teardown do
    @threads&.each { |thread| thread.kill if thread.alive? }
    @threads&.each(&:join)
    @projects&.each(&:destroy!)
  end

  test "concurrent claims make progress behind a full project's backlog without duplicating attempts" do
    full = create_workflow("full", max_concurrency: 1)
    create_job(full, "running", status: :running)
    40.times { |i| create_job(full, "backlog-#{i}") }

    workflows = %w[first second third].map { |name| create_workflow(name, max_concurrency: 2) }
    jobs = workflows.map { |workflow| create_job(workflow, "build") }
    first, remaining = hold_claim(runner("first")) do
      [claim_in_thread(runner("second")), claim_in_thread(runner("third"))]
    end
    claims = [first, *remaining]

    assert_equal jobs.map(&:id), claims.map { |job| job&.id }
    attempts = claims.map(&:attempt_token)
    assert attempts.all?(&:present?)
    assert_equal attempts, attempts.uniq
    assert_equal attempts, JobRun.where(id: jobs.map(&:id)).order(:id).pluck(:attempt_token)
    assert_nil JobRun.claim_next!(runner("extra"))
    assert_equal 40, full.job_runs.queued.count
  end

  test "claims with disjoint routing cannot reserve the same last project slot" do
    workflow = create_workflow("capped", max_concurrency: 2)
    create_job(workflow, "running", status: :running)
    first_job = create_job(workflow, "small", resource_class: "small")
    other_job = create_job(workflow, "large", resource_class: "large")
    fallback = create_job(create_workflow("other-project"), "large", resource_class: "large")

    first, second = hold_claim(runner("first", "small")) { claim_in_thread(runner("second", "large")) }

    assert_equal first_job.id, first&.id
    assert_equal 2, workflow.pipeline.project.active_job_count
    assert_equal fallback.id, second&.id
    assert other_job.reload.queued?
    assert_nil JobRun.claim_next!(runner("second", "large"))

    first.release!
    assert_equal other_job.id, JobRun.claim_next!(runner("second", "large"))&.id
  end

  test "a single queued job cannot be claimed while its first attempt is uncommitted" do
    job = create_job(create_workflow("single", max_concurrency: 2), "build")

    first, second = hold_claim(runner("runner")) { claim_in_thread(runner("runner")) }

    assert_equal job.id, first&.id
    assert_nil second
    assert first.attempt_token.present?
    assert_equal first.attempt_token, job.reload.attempt_token
  end

  test "capacity is rechecked after a competing claim commits" do
    workflow = create_workflow("last-slot")
    stale_candidate = create_job(workflow, "small", resource_class: "small")
    winner = create_job(workflow, "large", resource_class: "large")
    fallback = create_job(create_workflow("other-project"), "small", resource_class: "small")
    selected = Queue.new
    resume = Queue.new
    first = in_thread do
      claimant = Thread.current
      paused = false
      subscriber = lambda do |_name, _start, _finish, _id, payload|
        next if paused || Thread.current != claimant || !payload[:sql].match?(/FROM "job_runs".*SKIP LOCKED/)

        paused = true
        selected << true
        resume.pop
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        JobRun.claim_next!(runner("first", "small"))
      end
    end

    Timeout.timeout(10) do
      selected.pop
      assert_equal winner.id, claim_in_thread(runner("second", "large"))&.id
      resume << true
      assert_equal fallback.id, first.value&.id
    end
    assert stale_candidate.reload.queued?
    assert_equal 1, workflow.pipeline.project.active_job_count
  ensure
    resume << true if first&.alive?
  end

  private

  def create_workflow(name, max_concurrency: 1)
    project = Project.create!(name: name, max_concurrency: max_concurrency)
    @projects << project
    project.pipelines.create!(sha: "abc", branch: "main", status: :running)
           .workflow_runs.create!(name: "workflow", status: :running)
  end

  def create_job(workflow, name, **attrs)
    workflow.job_runs.create!({ name: name, status: :queued }.merge(attrs))
  end

  def runner(name, resource_class = nil)
    RunnerToken.new(name: name, resource_class: resource_class)
  end

  def in_thread(&block)
    Thread.new { JobRun.connection_pool.with_connection(&block) }.tap { |thread| @threads << thread }
  end

  def hold_claim(token)
    claimed = Queue.new
    release = Queue.new
    thread = in_thread do
      JobRun.transaction do
        job = JobRun.claim_next!(token)
        claimed << job
        release.pop
        job
      end
    end

    Timeout.timeout(10) do
      claimed.pop
      result = yield
      release << true
      [thread.value, result]
    end
  ensure
    release << true if thread&.alive?
  end

  def claim_in_thread(token)
    in_thread { JobRun.claim_next!(token) }.value
  end
end
