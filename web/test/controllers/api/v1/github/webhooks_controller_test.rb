# frozen_string_literal: true

require "test_helper"

class Api::V1::Github::WebhooksControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-webhook-secret"

  setup do
    @old_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = SECRET
  end

  teardown do
    ENV["GITHUB_WEBHOOK_SECRET"] = @old_secret
  end

  def signed_post(payload, event:, secret: SECRET, tamper: false)
    body = payload.to_json
    sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
    body += " " if tamper
    post "/api/v1/github/webhooks", params: body,
         headers: {
           "X-Hub-Signature-256" => sig,
           "X-GitHub-Event" => event,
           "CONTENT_TYPE" => "application/json"
         }
  end

  def push_payload(overrides = {})
    {
      "ref" => "refs/heads/main",
      "after" => "abc123def456",
      "deleted" => false,
      "repository" => { "full_name" => "octo/hello" },
      "installation" => { "id" => 42, "account" => { "login" => "octo" } }
    }.merge(overrides)
  end

  def pr_payload(fork:, action: "opened")
    {
      "action" => action,
      "pull_request" => {
        "head" => {
          "sha" => "forksha1", "ref" => "feature",
          "repo" => { "full_name" => fork ? "mallory/hello" : "octo/hello" }
        },
        "base" => { "repo" => { "full_name" => "octo/hello" } }
      },
      "installation" => { "id" => 42, "account" => { "login" => "octo" } }
    }
  end

  def last_enqueued_args
    ActiveJob::Base.queue_adapter.enqueued_jobs.last[:args].first
  end

  test "push with valid signature enqueues a sync job and returns 202" do
    assert_enqueued_with(job: Github::SyncPipelineJob) do
      signed_post(push_payload, event: "push")
    end
    assert_response :accepted
  end

  test "missing signature returns 401 and enqueues nothing" do
    assert_no_enqueued_jobs do
      post "/api/v1/github/webhooks", params: push_payload.to_json,
           headers: { "X-GitHub-Event" => "push", "CONTENT_TYPE" => "application/json" }
    end
    assert_response :unauthorized
  end

  test "wrong-secret signature returns 401" do
    signed_post(push_payload, event: "push", secret: "wrong-secret")
    assert_response :unauthorized
  end

  test "tampered body fails signature verification" do
    signed_post(push_payload, event: "push", tamper: true)
    assert_response :unauthorized
  end

  test "missing webhook secret fails closed with 401" do
    ENV["GITHUB_WEBHOOK_SECRET"] = nil
    signed_post(push_payload, event: "push")
    assert_response :unauthorized
  end

  test "tag push is ignored (202, no job)" do
    assert_no_enqueued_jobs do
      signed_post(push_payload("ref" => "refs/tags/v1.0"), event: "push")
    end
    assert_response :accepted
  end

  test "branch deletion push is ignored" do
    assert_no_enqueued_jobs do
      signed_post(push_payload("deleted" => true), event: "push")
    end
    assert_response :accepted
  end

  test "pull_request opened from a fork enqueues with forked=true" do
    signed_post(pr_payload(fork: true), event: "pull_request")
    assert_response :accepted
    args = last_enqueued_args
    assert_equal true, args["forked"]
    assert_equal "octo/hello", args["repo_full_name"]
    assert_equal "forksha1", args["sha"]
  end

  test "pull_request opened from the same repo enqueues with forked=false" do
    signed_post(pr_payload(fork: false), event: "pull_request")
    assert_response :accepted
    assert_equal false, last_enqueued_args["forked"]
  end

  test "pull_request synchronize enqueues; closed does not" do
    signed_post(pr_payload(fork: false, action: "synchronize"), event: "pull_request")
    assert_response :accepted
    assert_equal 1, ActiveJob::Base.queue_adapter.enqueued_jobs.size

    assert_no_enqueued_jobs do
      signed_post(pr_payload(fork: false, action: "closed"), event: "pull_request")
    end
    assert_response :accepted
  end

  test "installation created records the installation" do
    payload = {
      "action" => "created",
      "installation" => { "id" => 99, "account" => { "login" => "octo", "type" => "Organization" } }
    }
    signed_post(payload, event: "installation")
    assert_response :accepted
    inst = GithubInstallation.find_by(installation_id: 99)
    assert_equal "octo", inst.account_login
    assert_equal "Organization", inst.account_type
  end

  test "installation deleted removes the installation" do
    GithubInstallation.create!(installation_id: 100, account_login: "octo")
    signed_post({ "action" => "deleted", "installation" => { "id" => 100 } }, event: "installation")
    assert_response :accepted
    assert_nil GithubInstallation.find_by(installation_id: 100)
  end

  test "ping returns 200 and unknown events are ignored with 202" do
    signed_post({ "zen" => "Keep it logically awesome." }, event: "ping")
    assert_response :ok

    assert_no_enqueued_jobs do
      signed_post({ "zen" => "hi" }, event: "membership")
    end
    assert_response :accepted
  end

  test "invalid JSON returns 400" do
    body = "not json{"
    sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', SECRET, body)}"
    post "/api/v1/github/webhooks", params: body,
         headers: { "X-Hub-Signature-256" => sig, "X-GitHub-Event" => "push",
                    "CONTENT_TYPE" => "application/json" }
    assert_response :bad_request
  end
end
