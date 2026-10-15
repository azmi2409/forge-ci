# frozen_string_literal: true

require "net/http"
require "uri"

module Github
  # Authenticated GitHub API client for one App installation.
  #
  # Auth flow (documented GitHub REST API):
  #   1. Build a short-lived app JWT (RS256) from GITHUB_APP_ID +
  #      GITHUB_APP_PRIVATE_KEY.
  #   2. POST /app/installations/:installation_id/access_tokens with the JWT
  #      to get an installation token (valid 1 hour).
  #   3. Use the installation token for repo API calls; cache it until
  #      shortly before expiry.
  #
  # Only net/http from stdlib plus the `jwt` gem — no other dependencies.
  class AppClient
    API_BASE = "https://api.github.com"
    TOKEN_REFRESH_MARGIN = 5.minutes
    JWT_TTL = 10.minutes

    class ApiError < StandardError
      attr_reader :status, :body

      def initialize(status, body)
        @status = status
        @body = body
        super("GitHub API error #{status}: #{body.to_s.truncate(200)}")
      end
    end

    class NotConfigured < StandardError; end

    def initialize(installation_id:)
      @installation_id = installation_id
    end

    # --- high-level operations -------------------------------------------

    # Fetch .circleci/config.yml at a commit SHA. Returns the decoded YAML
    # string, or nil when the repo has no config file at that SHA.
    def fetch_config(full_name, sha)
      res = get("/repos/#{full_name}/contents/.circleci/config.yml?ref=#{sha}")
      return nil if res[:status] == 404
      raise ApiError.new(res[:status], res[:body]) unless res[:status] == 200

      body = res[:body]
      raise ApiError.new(200, "unexpected contents response") unless body["encoding"] == "base64"

      Base64.decode64(body["content"].delete("\n"))
    end

    # POST /repos/:full_name/statuses/:sha
    def create_commit_status(full_name, sha, state:, description:, target_url: nil, context: "forge-ci")
      payload = {
        state: state,
        context: context,
        description: description.to_s.truncate(140)
      }
      payload[:target_url] = target_url if target_url.present?
      res = post("/repos/#{full_name}/statuses/#{sha}", payload)
      raise ApiError.new(res[:status], res[:body]) unless res[:status] == 201

      res[:body]
    end

    # --- auth ---------------------------------------------------------------

    # Installation token, cached until TOKEN_REFRESH_MARGIN before expiry.
    def installation_token
      cached = Rails.cache.read(token_cache_key)
      return cached if cached.present?

      token, expires_at = request_installation_token
      ttl = expires_at - Time.current - TOKEN_REFRESH_MARGIN
      Rails.cache.write(token_cache_key, token, expires_in: ttl.positive? ? ttl : 1.minute)
      token
    end

    private

    def token_cache_key
      "github:installation_token:#{@installation_id}"
    end

    def app_jwt
      raise NotConfigured, Github::CONFIG_MISSING_MESSAGE unless Github.configured?

      payload = {
        iat: (Time.current - 60.seconds).to_i,
        exp: (Time.current + JWT_TTL).to_i,
        iss: Github.app_id.to_s
      }
      JWT.encode(payload, OpenSSL::PKey::RSA.new(Github.private_key_pem), "RS256")
    end

    # Exchange the app JWT for an installation token.
    # Returns [token, expires_at].
    def request_installation_token
      res = api_request(:post, "/app/installations/#{@installation_id}/access_tokens",
                        bearer: app_jwt)
      raise ApiError.new(res[:status], res[:body]) unless res[:status] == 201

      [res[:body]["token"], Time.zone.parse(res[:body]["expires_at"])]
    end

    def get(path)
      api_request(:get, path, bearer: installation_token)
    end

    def post(path, payload)
      api_request(:post, path, bearer: installation_token, payload: payload)
    end

    # Raw request returning { status:, body: } (body parsed as JSON when
    # possible). Raises ApiError only for transport-level failures.
    def api_request(method, path, bearer:, payload: nil)
      uri = URI.join(API_BASE, path)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30

      request =
        case method
        when :get then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ArgumentError, "unsupported method #{method}"
        end
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{bearer}"
      request["User-Agent"] = "forge-ci"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      if payload
        request["Content-Type"] = "application/json"
        request.body = JSON.dump(payload)
      end

      response = http.request(request)
      body =
        begin
          JSON.parse(response.body)
        rescue JSON::ParserError, TypeError
          response.body
        end
      { status: response.code.to_i, body: body }
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError => e
      raise ApiError.new(0, "transport error: #{e.class}: #{e.message}")
    end
  end
end
