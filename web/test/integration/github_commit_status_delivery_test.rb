# frozen_string_literal: true

require "test_helper"

# GitHub webhook → pipeline → commit status, against FakeGithub: duplicate
# deliveries, and statuses that must survive GitHub rate limits, 5xx and
# network failures instead of leaving the PR check pending or missing.
class GithubCommitStatusDeliveryTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = "test-webhook-secret"
  SHA = "abc123def456"

  setup do
    @old_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = SECRET
    @github = FakeGithub.new(config_yaml: file_fixture("ci_config.yml").read)
  end

  teardown do
    ENV["GITHUB_WEBHOOK_SECRET"] = @old_secret
  end

  def deliver_push_webhook(delivery_id: SecureRandom.uuid)
    body = {
      "ref" => "refs/heads/main", "after" => SHA, "deleted" => false,
      "repository" => { "full_name" => "octo/hello" },
      "installation" => { "id" => 42, "account" => { "login" => "octo" } }
    }.to_json
    perform_enqueued_jobs do
      post "/api/v1/github/webhooks", params: body, headers: {
        "X-Hub-Signature-256" => "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, body)}",
        "X-GitHub-Event" => "push",
        "X-GitHub-Delivery" => delivery_id,
        "CONTENT_TYPE" => "application/json"
      }
    end
    assert_response :accepted
  end

  def finish_pipeline(pipeline, status)
    perform_enqueued_jobs do
      until pipeline.reload.job_runs.all?(&:terminal?)
        pipeline.job_runs.where(status: %w[pending queued]).each do |job|
          next if job.reload.canceled?

          job.mark_queued! if job.pending?
          job.mark_claimed!(claimed_by: "test")
          job.mark_running!
          job.complete_with_results!(status: status)
        end
      end
    end
    pipeline.reload
  end

  def states
    @github.statuses.map { |status| status["state"] }
  end

  test "duplicate webhook deliveries build the commit once and post one pending status" do
    @github.install do
      delivery_id = SecureRandom.uuid
      deliver_push_webhook(delivery_id: delivery_id)
      deliver_push_webhook(delivery_id: delivery_id) # GitHub redelivery
      deliver_push_webhook                            # pull_request event for the same commit
    end

    assert_equal 1, Pipeline.where(sha: SHA).count
    assert_equal %w[pending], states
  end

  test "pending status is retried through GitHub 503 and 429 responses" do
    @github.fail_status_posts(503, 429)
    @github.install { deliver_push_webhook }

    assert_equal 3, @github.status_post_attempts
    assert_equal %w[pending], states
    assert_equal SHA, @github.statuses.last["sha"]
  end

  test "terminal status is retried through a network failure and a 502" do
    @github.install do
      deliver_push_webhook
      @github.fail_status_posts(Errno::ECONNRESET.new, 502)
      finish_pipeline(Pipeline.find_by!(sha: SHA), "success")
    end

    assert_equal %w[pending success], states
  end

  test "a pending status recorded after the build finished does not replace the result" do
    @github.install do
      deliver_push_webhook
      pipeline = finish_pipeline(Pipeline.find_by!(sha: SHA), "success")
      perform_enqueued_jobs { Github::StatusPoster.post_pending(pipeline) } # late intake post

      assert_equal "success", pipeline.github_commit_status.reload.state
    end

    assert_equal %w[pending success], states
  end

  test "config fetch is retried through a GitHub 502 so the push still gets a pipeline" do
    @github.fail_config_fetches(502)
    @github.install { deliver_push_webhook }

    assert_equal 1, Pipeline.where(sha: SHA).count
    assert_equal %w[pending], states
  end

  test "a redelivered webhook re-sends a status GitHub never received" do
    @github.fail_status_posts(*Array.new(10, 503))
    @github.install do
      deliver_push_webhook
      assert_empty states, "every attempt failed"

      deliver_push_webhook # "Redeliver" from the App's Recent Deliveries tab
    end

    assert_equal 1, Pipeline.where(sha: SHA).count
    assert_equal %w[pending], states
  end

  test "a rejected status (422) is not retried" do
    @github.fail_status_posts(422)
    @github.install { deliver_push_webhook }

    assert_equal 1, @github.status_post_attempts
    assert_empty states
  end

  test "statuses are posted outside the intake transaction" do
    outer = ActiveRecord::Base.connection.open_transactions
    open_during_post = []
    @github.on_status_post = -> { open_during_post << ActiveRecord::Base.connection.open_transactions }
    @github.install { deliver_push_webhook }

    assert_equal [outer], open_during_post
  end
end
