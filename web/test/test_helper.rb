# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
# Keep the SSE live-tail test fast: a live (non-terminal) job's stream would
# otherwise hold the full 5-minute production timeout open.
ENV["FORGE_CI_STREAM_TIMEOUT_SECONDS"] ||= "2"
TEST_ADMIN_TOKEN = "test-admin-token-123"
ENV["FORGE_CI_ADMIN_TOKEN"] = TEST_ADMIN_TOKEN
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Compile the fixture config with the REAL forge-ci gem and return the IR
    # with string keys — exactly what the intake endpoint receives over HTTP
    # after the JSON round-trip.
    def compile_test_ir
      yaml = file_fixture("ci_config.yml").read
      ir, errors = ForgeCI::Compiler.compile(yaml)
      assert_empty errors, "fixture failed to compile: #{errors.inspect}"
      ::JSON.parse(ir.to_json)
    end

    def admin_headers
      { "Authorization" => "Bearer #{TEST_ADMIN_TOKEN}" }
    end

    def bearer_headers(raw_token)
      { "Authorization" => "Bearer #{raw_token}" }
    end

    def ui_basic_auth_headers(user = "admin", password = "password")
      { "Authorization" => "Basic #{Base64.strict_encode64("#{user}:#{password}")}" }
    end

    def json_body
      ::JSON.parse(response.body)
    end
  end
end
