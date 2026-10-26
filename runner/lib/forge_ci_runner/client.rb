# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "timeout"
require "securerandom"
require "socket"

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
      @runner_id = SecureRandom.uuid
      @runner_hostname = begin
        Socket.gethostname.b.gsub(/[^\x20-\x7e]/, "").strip[0, 255].rstrip
      rescue SocketError, SystemCallError
        "unknown"
      end
      @runner_hostname = "unknown" if @runner_hostname.empty?
    end

    # POST /api/v1/runner/jobs/claim — returns the job payload Hash,
    # or nil when the server answers 422 (nothing claimable).
    # Jobs of this runner's class waiting on earlier jobs, from the last
    # claim that found nothing (0 from older servers).
    attr_reader :upcoming

    def claim_job(resource_class, timeout: nil)
      body = {}
      body["resource_class"] = resource_class if resource_class
      @upcoming = 0
      post("/api/v1/runner/jobs/claim", body, timeout: timeout)
    rescue HTTPError => e
      if e.code == "422"
        @upcoming = (JSON.parse(e.body.to_s)["upcoming"].to_i rescue 0)
        return nil
      end

      raise
    end

    # GET /api/v1/runner/outlook — aggregate counts scoped to this token's
    # trust pool and the runner's class (plus classless jobs).
    def outlook(resource_class, timeout: nil)
      path = "/api/v1/runner/outlook"
      path += "?#{URI.encode_www_form(resource_class: resource_class)}" unless resource_class.to_s.empty?
      get(path, timeout: timeout)
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

    # POST /api/v1/runner/jobs/:id/release { reason } — hand a claimed or
    # running job back to the queue (REQUEUE_ON_SHUTDOWN). Raises HTTPError
    # 409 once the job has been released too often.
    def release_job(job_id, reason)
      post("/api/v1/runner/jobs/#{job_id}/release", { "reason" => reason })
    end

    # POST /api/v1/jobs/:id/log_chunks — idempotent upsert on (job, seq).
    def post_log_chunk(job_id, seq, chunk)
      post("/api/v1/jobs/#{job_id}/log_chunks", { "seq" => seq, "chunk" => chunk })
    end

    # PUT /api/v1/projects/:id/cache — multipart: key, file (tarball).
    # Upserts on (project_id, key). Returns { "key", "size" }.
    def put_cache(project_id, key, tarball_path)
      body = Multipart::Body.new(
        { "key" => key },
        [{ name: "file", filename: File.basename(tarball_path),
           path: tarball_path, content_type: "application/gzip" }]
      )
      request_multipart(:put, "/api/v1/projects/#{project_id}/cache", body)
    end

    # GET /api/v1/projects/:id/cache?keys[]=k1&keys[]=k2 — the server tries
    # the keys in order (exact match, then longest-prefix fallback).
    # Returns the hit hash ({ "key", "size", "download_url" }) or nil on 404.
    def get_cache(project_id, keys)
      query = URI.encode_www_form(Array(keys).map { |k| ["keys[]", k] })
      get("/api/v1/projects/#{project_id}/cache?#{query}")
    rescue HTTPError => e
      return nil if e.code == "404"

      raise
    end

    # POST /api/v1/jobs/:id/artifacts — multipart: file, path, destination?.
    # Returns the artifact hash including a 15-minute download_url.
    def post_artifact(job_id, local_path, path:, destination: nil)
      fields = { "path" => path }
      fields["destination"] = destination unless destination.nil? || destination.to_s.empty?
      body = Multipart::Body.new(
        fields,
        [{ name: "file", filename: File.basename(local_path), path: local_path }]
      )
      request_multipart(:post, "/api/v1/jobs/#{job_id}/artifacts", body)
    end

    # Downloads a (signed) URL to a local file. No Authorization header —
    # the URL is pre-authenticated. Follows up to 3 redirects.
    def download(url, dest_path, limit = 3)
      raise HTTPError.new("0", "too many redirects") if limit.zero?

      uri = URI.parse(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: 10, read_timeout: 120) do |http|
        http.request_get(uri.request_uri) do |resp|
          case resp
          when Net::HTTPRedirection
            location = resp["location"]
            raise HTTPError.new(resp.code, "redirect without location") if location.nil?

            return download(URI.join(url, location).to_s, dest_path, limit - 1)
          when Net::HTTPSuccess
            File.open(dest_path, "wb") do |f|
              resp.read_body { |chunk| f.write(chunk) }
            end
            return dest_path
          else
            raise HTTPError.new(resp.code, resp.body.to_s[0, 200])
          end
        end
      end
    end

    private

    def get(path, timeout: nil)
      uri = URI.join(@base + "/", path.sub(%r{\A/}, ""))
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      request_timeout = timeout.to_f if timeout
      request_timeout = nil unless request_timeout&.positive?
      http_request = lambda do
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: request_timeout ? [10.0, request_timeout].min : 10,
                        read_timeout: request_timeout ? [60.0, request_timeout].min : 60) do |http|
          http.request(request)
        end
      end
      response = request_timeout ? Timeout.timeout(request_timeout, &http_request) : http_request.call

      parse_response(response)
    end

    def request_multipart(method, path, body)
      uri = URI.join(@base + "/", path.sub(%r{\A/}, ""))
      klass = method == :put ? Net::HTTP::Put : Net::HTTP::Post
      request = klass.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/json"
      request["Content-Type"] = body.content_type
      request["Content-Length"] = body.size.to_s
      request.body_stream = body

      response = Net::HTTP.start(uri.host, uri.port,
                                 use_ssl: uri.scheme == "https",
                                 open_timeout: 10, read_timeout: 300) do |http|
        http.request(request)
      end

      parse_response(response)
    end

    def post(path, payload, timeout: nil)
      uri = URI.join(@base + "/", path.sub(%r{\A/}, ""))
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["X-Forge-Runner-ID"] = @runner_id
      request["X-Forge-Runner-Hostname"] = @runner_hostname
      request["X-Forge-Runner-Implementation"] = "ruby"
      request.body = JSON.generate(payload)
      request_timeout = timeout.to_f if timeout
      request_timeout = nil unless request_timeout&.positive?
      http_request = lambda do
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: request_timeout ? [10.0, request_timeout].min : 10,
                        read_timeout: request_timeout ? [60.0, request_timeout].min : 60) do |http|
          http.request(request)
        end
      end
      response = request_timeout ? Timeout.timeout(request_timeout, &http_request) : http_request.call

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
