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
end
