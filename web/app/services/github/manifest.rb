# frozen_string_literal: true

require "net/http"
require "uri"

module Github
  # GitHub's app-manifest flow: POST a manifest to github.com, the user
  # confirms, GitHub redirects back with a one-time code that converts into the
  # new App's id, private key and webhook secret.
  # https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest
  module Manifest
    module_function

    # The manifest for an App pointing at +base_url+ (this control plane).
    def build(base_url)
      host = URI.parse(base_url).host.to_s
      {
        name: "ForgeCI #{host}".strip[0, 34],
        url: base_url,
        hook_attributes: { url: "#{base_url}/api/v1/github/webhooks", active: true },
        redirect_url: "#{base_url}/settings/github/callback",
        public: false,
        default_permissions: { contents: "read", statuses: "write", pull_requests: "read", metadata: "read" },
        default_events: %w[push pull_request]
      }
    end

    # Where the manifest form posts: a personal App, or one owned by +org+.
    def new_app_url(org: nil, state:)
      base = org.present? ? "https://github.com/organizations/#{ERB::Util.url_encode(org)}/settings/apps/new" : "https://github.com/settings/apps/new"
      "#{base}?state=#{ERB::Util.url_encode(state)}"
    end

    # Factory seam: tests swap in a fake converter.
    class << self
      attr_writer :converter

      def converter
        @converter ||= method(:convert_via_api)
      end
    end

    # Returns the conversion response Hash (id, slug, pem, webhook_secret, ...).
    def convert(code)
      converter.call(code)
    end

    def convert_via_api(code)
      uri = URI("https://api.github.com/app-manifests/#{ERB::Util.url_encode(code)}/conversions")
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["User-Agent"] = "forge-ci"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
      raise Github::AppClient::ApiError.new(response.code.to_i, response.body) unless response.code.to_i == 201

      JSON.parse(response.body)
    end
  end
end
