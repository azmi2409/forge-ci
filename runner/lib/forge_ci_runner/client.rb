# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module ForgeCIRunner
  # Minimal HTTP client for the control plane Runner API.
  # Built exactly against the contract documented in web/README.md —
  # no invented endpoints.
  class Client
    class HTTPError < StandardError
      attr_reader :code, :body

      def initialize(code, body)
        @code = code
        @body = body
        super("HTTP #{code}: #{body.to_s[0, 200]}")
      end
    end

    def initialize(config)
      @base = config.control_plane_url
      @token = config.runner_token
    end

    # POST /api/v1/runner/jobs/claim — returns the job payload Hash,
    # or nil when the server answers 422 (nothing claimable).
    def claim_job(resource_class)
      body = {}
      body["resource_class"] = resource_class if resource_class
      post("/api/v1/runner/jobs/claim", body)
    rescue HTTPError => e
      return nil if e.code == "422"

      raise
    end

    # POST /api/v1/runner/jobs/:id/start
    def start_job(job_id)
      post("/api/v1/runner/jobs/#{job_id}/start", {})
    end

    # POST /api/v1/runner/jobs/:id/heartbeat
    def heartbeat(job_id)
      post("/api/v1/runner/jobs/#{job_id}/heartbeat", {})
    end

    # POST /api/v1/runner/jobs/:id/complete
    # status: "success" | "failed" | "canceled"
    # step_results: [{ "name", "exit_code", "started_at", "finished_at" }]
    def complete_job(job_id, status, step_results)
      post("/api/v1/runner/jobs/#{job_id}/complete",
           { "status" => status, "step_results" => step_results })
    end

    # POST /api/v1/jobs/:id/log_chunks — idempotent upsert on (job, seq).
    def post_log_chunk(job_id, seq, chunk)
      post("/api/v1/jobs/#{job_id}/log_chunks", { "seq" => seq, "chunk" => chunk })
    end

    private

    def post(path, payload)
      uri = URI.join(@base + "/", path.sub(%r{\A/}, ""))
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(payload)

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: 10, read_timeout: 60) do |http|
        http.request(request)
      end

      parse_response(response)
    end

    def parse_response(response)
      code = response.code
      body = response.body.to_s
      parsed = body.empty? ? {} : JSON.parse(body)
      return parsed if code.start_with?("2")

      raise HTTPError.new(code, body)
    rescue JSON::ParserError
      raise HTTPError.new(code, body) unless code.start_with?("2")

      {}
    end
  end
end
