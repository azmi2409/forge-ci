# frozen_string_literal: true

require "test_helper"

class Github::AppClientTest < ActiveSupport::TestCase
  setup do
    @key = OpenSSL::PKey::RSA.new(2048)
    @old_env = {
      "GITHUB_APP_ID" => ENV["GITHUB_APP_ID"],
      "GITHUB_APP_PRIVATE_KEY" => ENV["GITHUB_APP_PRIVATE_KEY"]
    }
    ENV["GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_APP_PRIVATE_KEY"] = @key.to_pem
    @client = Github::AppClient.new(installation_id: 42)
    # Test env uses :null_store; the token cache needs a real store here.
    @old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    @old_env.each { |k, v| ENV[k] = v }
    Rails.cache = @old_cache
  end

  test "app_jwt is a valid RS256 JWT carrying iss, iat and exp" do
    token = @client.send(:app_jwt)
    decoded, header = JWT.decode(token, @key.public_key, true, algorithm: "RS256")
    assert_equal "RS256", header["alg"]
    assert_equal "12345", decoded["iss"]
    assert decoded["exp"] > decoded["iat"]
    assert_in_delta Time.current.to_i + 600, decoded["exp"], 30
  end

  test "missing app config raises NotConfigured" do
    ENV["GITHUB_APP_ID"] = nil
    assert_raises(Github::AppClient::NotConfigured) { @client.send(:app_jwt) }
  end

  test "installation_token caches the exchanged token until near expiry" do
    test_client_class = Class.new(Github::AppClient) do
      attr_reader :exchange_calls

      def initialize(**kwargs)
        super
        @exchange_calls = 0
      end

      private

      def request_installation_token
        @exchange_calls += 1
        ["tok123", 1.hour.from_now]
      end
    end

    client = test_client_class.new(installation_id: 42)
    assert_equal "tok123", client.installation_token
    assert_equal "tok123", client.installation_token
    assert_equal 1, client.exchange_calls, "token exchange should happen once, then come from cache"
  end
end
