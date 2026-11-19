# frozen_string_literal: true

require "test_helper"
require "timeout"

class JobLockOrderTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  teardown do
    @threads&.each { |thread| thread.kill if thread.alive? }
    @threads&.each(&:join)
    @project&.destroy!
  end

  test "concurrent prerequisite completions queue their shared dependent" do
    complete_prerequisites_concurrently("success")
  end

  test "concurrent prerequisite failures cancel their shared dependent" do
    complete_prerequisites_concurrently("failed")
  end

  test "completion release and reclaim acquire the workflow lock before the job lock" do
    skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    @project = Project.create!(name: "workflow-lock-order")
    %i[complete_with_results! release! reclaim_stale!].each do |operation|
      pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "running")
      workflow = pipeline.workflow_runs.create!(name: "wf", status: "running")
      job = workflow.job_runs.create!(name: "build", status: "running", heartbeat_at: 5.minutes.ago,
                                     executor: { "type" => "docker" })

      assert_workflow_before_job(job) do
        current = JobRun.find(job.id)
        operation == :complete_with_results! ? current.complete_with_results!(status: "success") : current.public_send(operation)
      end
    end
  end

  test "rerun acquires workflow locks before job locks" do
    skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    @project = Project.create!(name: "rerun-lock-order")
    pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "failed")
    workflow = pipeline.workflow_runs.create!(name: "wf", status: "failed")
    job = workflow.job_runs.create!(name: "build", status: "failed", executor: { "type" => "docker" })

    assert_workflow_before_job(job) { Pipeline.find(pipeline.id).rerun! }

    assert job.reload.queued?
  end

  test "pipeline cancellation releases earlier jobs before waiting for a completing job" do
    skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    @project = Project.create!(name: "cancel-lock-order")
    pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    workflow = pipeline.workflow_runs.create!(name: "wf", status: "running")
    dependent = workflow.job_runs.create!(name: "deploy", requires: ["build"], executor: { "type" => "docker" })
    completing = workflow.job_runs.create!(name: "build", status: "running", executor: { "type" => "docker" })
    locked = Queue.new
    canceled = Queue.new
    errors = Queue.new

    selection = Object.new
    selection.define_singleton_method(:where) { selection }
    selection.define_singleton_method(:not) { |**_kwargs| selection }
    selection.define_singleton_method(:find_each) do |&block|
      block.call(JobRun.find(dependent.id))
      canceled << true
      block.call(JobRun.find(completing.id))
    end
    pipeline.define_singleton_method(:job_runs) { selection }

    @threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '5s'")
          begin
            job = JobRun.find(completing.id)
            job.with_lock do
              locked << true
              canceled.pop
              job.complete_with_results!(status: "success")
            end
          rescue StandardError => e
            errors << e
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '5s'")
          begin
            locked.pop
            pipeline.cancel!
          rescue StandardError => e
            errors << e
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end
    ]
    Timeout.timeout(15) { @threads.each(&:join) }

    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert completing.reload.success?
    assert dependent.reload.canceled?
  end

  private

  def assert_workflow_before_job(job)
    errors = Queue.new
    started = Queue.new
    thread = nil
    job.workflow_run.with_lock do
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '5s'")
          begin
            started << connection.raw_connection.backend_pid
            yield
          rescue StandardError => e
            errors << e
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end
      (@threads ||= []) << thread
      Timeout.timeout(15) { wait_for_lock_or_completion(thread, started.pop) }
      assert thread.alive?, "operation should wait for the workflow lock"
      job.with_lock("FOR UPDATE NOWAIT") { assert job.persisted? }
    end
    Timeout.timeout(15) { thread.join }
    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
  end

  def wait_for_lock_or_completion(thread, pid)
    ActiveRecord::Base.uncached do
      while thread.alive? && !ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid})) > 0")
        sleep 0.01
      end
    end
  end

  def complete_prerequisites_concurrently(status)
    skip "requires PostgreSQL row locks" unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

    @project = Project.create!(name: "concurrent-prerequisites")
    pipeline = @project.pipelines.create!(sha: "abc", branch: "main", status: "running")
    workflow = pipeline.workflow_runs.create!(name: "wf", status: "running")
    first, second = %w[build test].map do |name|
      workflow.job_runs.create!(name: name, status: "running", executor: { "type" => "docker" })
    end
    dependent = workflow.job_runs.create!(name: "deploy", requires: %w[build test], executor: { "type" => "docker" })
    resolved = Queue.new
    release = Queue.new
    second_pid = Queue.new
    errors = Queue.new
    resolution = status == "success" ? :unblock_dependents! : :cancel_unreachable_dependents!
    first.define_singleton_method(resolution) do
      super()
      resolved << true
      release.pop
    end

    @threads = [Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '5s'")
        begin
          first.complete_with_results!(status: status)
        rescue StandardError => e
          errors << e
        ensure
          connection.execute("RESET lock_timeout")
        end
      end
    end]

    Timeout.timeout(15) do
      resolved.pop
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          connection.execute("SET lock_timeout = '5s'")
          begin
            second_pid << connection.raw_connection.backend_pid
            JobRun.find(second.id).complete_with_results!(status: status)
          rescue StandardError => e
            errors << e
          ensure
            connection.execute("RESET lock_timeout")
          end
        end
      end
      pid = second_pid.pop
      wait_for_lock_or_completion(@threads.last, pid)
      release << true
      @threads.each(&:join)
    end

    assert errors.empty?, errors.size.times.map { errors.pop.full_message }.join("\n")
    assert_equal status, first.reload.status
    assert_equal status, second.reload.status
    assert_equal(status == "success" ? "queued" : "canceled", dependent.reload.status)
  end
end
