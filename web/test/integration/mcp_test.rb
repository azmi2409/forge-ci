# frozen_string_literal: true

require "test_helper"

class McpTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "owner/repo", max_concurrency: 4)
  end

  test "unauthenticated requests advertise public OAuth discovery" do
    sign_in_as_admin
    rpc("tools/list", headers: {})
    assert_response :unauthorized
    assert_equal 'Bearer resource_metadata="http://www.example.com/.well-known/oauth-protected-resource/mcp", scope="api"',
                 response.headers["WWW-Authenticate"]

    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :ok
    assert_equal "http://www.example.com/mcp", json_body["resource"]
    issuer = json_body.fetch("authorization_servers").sole
    get URI(issuer).path + "/.well-known/oauth-authorization-server"
    assert_response :ok
    assert_equal issuer, json_body["issuer"]
    assert_equal "#{issuer}/oauth/authorize", json_body["authorization_endpoint"]
    assert_equal "#{issuer}/oauth/token", json_body["token_endpoint"]
    assert_equal "#{issuer}/oauth/revoke", json_body["revocation_endpoint"]
    assert_equal ["S256"], json_body["code_challenge_methods_supported"]
  end

  test "runner credentials and a cross-origin request cannot use MCP" do
    _runner, raw = RunnerToken.generate!(name: "mcp-test", resource_class: "default")
    rpc("tools/list", headers: bearer_headers(raw))
    assert_response :unauthorized

    rpc("tools/list", headers: admin_headers.merge("Origin" => "https://elsewhere.example"))
    assert_response :forbidden
  end

  test "streamable HTTP initialization and tool discovery work with a shared token" do
    rpc("initialize", params: {
      protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "forge-ci-test", version: "1" }
    })
    assert_response :ok
    assert_equal "forge-ci", json_body.dig("result", "serverInfo", "name")
    assert_equal "2025-11-25", json_body.dig("result", "protocolVersion")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Mcp-Session-Id"]

    rpc("notifications/initialized", id: nil)
    assert_response :accepted
    assert_empty response.body

    rpc("tools/list")
    assert_response :ok
    assert_equal %w[cancel_pipeline get_job get_job_logs get_pipeline list_pipelines list_projects rerun_pipeline trigger_pipeline],
                 json_body.dig("result", "tools").pluck("name").sort

    get "/mcp", headers: admin_headers.merge("Accept" => "text/event-stream")
    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  test "a registered OAuth client can authorize with PKCE and acts as the member" do
    redirect_uri = "https://agent.example/callback"
    app = Doorkeeper::Application.create!(name: "MCP agent", redirect_uri: redirect_uri, scopes: "api", confidential: false)
    sign_in_as("mcp-member", role: :member)
    verifier = SecureRandom.urlsafe_base64(48)
    challenge = Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
    params = { client_id: app.uid, redirect_uri: redirect_uri, response_type: "code", scope: "api",
               state: "mcp-test-state", code_challenge: challenge, code_challenge_method: "S256" }
    get "/oauth/authorize", params: params.merge(resource: "http://www.example.com/mcp")
    assert_response :ok
    post "/oauth/authorize", params: params
    assert_response :redirect
    callback = URI(redirect_to_url)
    assert_equal "agent.example", callback.host
    query = URI.decode_www_form(callback.query).to_h
    assert_equal "mcp-test-state", query["state"]
    post "/oauth/token", params: { grant_type: "authorization_code", code: query.fetch("code"),
                                  redirect_uri: redirect_uri, client_id: app.uid, code_verifier: verifier,
                                  resource: "http://www.example.com/mcp" }
    assert_response :ok
    token = json_body.fetch("access_token")
    headers = bearer_headers(token)

    assert_equal [@project.id], call_tool("list_projects", headers: headers).fetch("projects").pluck("id")
    rpc("tools/list", headers: headers)
    assert_not_includes json_body.dig("result", "tools").pluck("name"), "trigger_pipeline"
    assert_no_difference -> { Pipeline.count } do
      rpc("tools/call", params: { name: "trigger_pipeline", arguments: trigger_args }, headers: headers)
    end
    assert json_body.key?("error")

    post "/oauth/revoke", params: { token: token, client_id: app.uid }
    assert_response :ok
    rpc("tools/list", headers: headers)
    assert_response :unauthorized
  end

  test "tools inspect projects, pipelines, and jobs and bound job log output" do
    assert_equal [@project.id], call_tool("list_projects").fetch("projects").pluck("id")
    pipeline = call_tool("trigger_pipeline", trigger_args)
    matching = call_tool("list_pipelines", { project_id: @project.id, branch: "main", limit: 1 })
    assert_equal [pipeline["id"]], matching.fetch("pipelines").pluck("id")
    assert_empty call_tool("list_pipelines", { project_id: @project.id, sha: "other" }).fetch("pipelines")
    assert_equal pipeline, call_tool("get_pipeline", { pipeline_id: pipeline["id"] })

    job_id = pipeline.fetch("workflows").first.fetch("jobs").first.fetch("id")
    job = call_tool("get_job", { job_id: job_id })
    assert_equal pipeline["id"], job["pipeline_id"]
    assert_equal "queued", job["status"]
    JobRun.find(job_id).append_log_chunk!(1, "x" * 64.kilobytes + "last line")
    logs = call_tool("get_job_logs", { job_id: job_id })
    assert logs["truncated"]
    assert_equal 64.kilobytes, logs.fetch("log").bytesize
    assert logs.fetch("log").end_with?("last line")
  end

  test "tools cancel and rerun an existing pipeline, and report invalid calls" do
    pipeline_id = call_tool("trigger_pipeline", trigger_args).fetch("id")
    rpc("tools/call", params: { name: "rerun_pipeline", arguments: { pipeline_id: pipeline_id } })
    assert json_body.dig("result", "isError")
    rpc("tools/call", params: { name: "list_pipelines", arguments: { project_id: @project.id, limit: 101 } })
    assert json_body.dig("result", "isError")
    rpc("tools/call", params: { name: "get_job", arguments: { job_id: JobRun.maximum(:id) + 1 } })
    assert json_body.dig("result", "isError")

    assert_equal "canceled", call_tool("cancel_pipeline", { pipeline_id: pipeline_id })["status"]
    rerun = call_tool("rerun_pipeline", { pipeline_id: pipeline_id, scope: "all" })
    assert_operator rerun["jobs_reset"], :>, 0
    assert_equal "running", rerun.dig("pipeline", "status")
  end

  private

  def trigger_args
    { project_id: @project.id, sha: "abc123", branch: "main", ir: compile_test_ir }
  end

  def rpc(method, params: nil, headers: admin_headers, id: 1)
    body = { jsonrpc: "2.0", method: method, params: params, id: id }.compact
    post "/mcp", params: body, as: :json,
         headers: { "Accept" => "application/json, text/event-stream", "MCP-Protocol-Version" => "2025-11-25" }.merge(headers)
  end

  def call_tool(name, arguments = {}, headers: admin_headers)
    rpc("tools/call", params: { name: name, arguments: arguments }, headers: headers)
    assert_response :ok
    result = json_body.fetch("result")
    assert_not result["isError"], result.inspect
    result.fetch("structuredContent")
  end
end
