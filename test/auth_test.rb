# frozen_string_literal: true

require "test_helper"
require "forge_ci/auth"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"

class AuthTest < Minitest::Test
  def with_credentials_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "credentials.json")
      original = ENV["FORGE_CI_CREDENTIALS"]
      ENV["FORGE_CI_CREDENTIALS"] = path
      yield path
    ensure
      ENV["FORGE_CI_CREDENTIALS"] = original
    end
  end

  # -- PKCE --------------------------------------------------------------------

  # Known-answer vector from RFC 7636 appendix B.
  def test_s256_code_challenge_matches_the_rfc_vector
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 ForgeCI::Auth.code_challenge(verifier)
  end

  def test_generated_verifiers_are_long_and_url_safe
    3.times do
      verifier = ForgeCI::Auth.generate_verifier
      assert_match(/\A[A-Za-z0-9_-]{43,128}\z/, verifier)
    end
  end

  def test_authorize_url_carries_pkce_state_and_client
    url = ForgeCI::Auth.authorize_url(url: "https://ci.example.com/",
                                       redirect_uri: "http://127.0.0.1:1234/callback",
                                       challenge: "CHA", state: "ST")
    parsed = URI.parse(url)
    assert_equal "https://ci.example.com", "#{parsed.scheme}://#{parsed.host}"
    assert_equal "/oauth/authorize", parsed.path
    assert_equal({ "client_id" => "forge-ci-cli",
                   "redirect_uri" => "http://127.0.0.1:1234/callback",
                   "response_type" => "code", "scope" => "api", "state" => "ST",
                   "code_challenge" => "CHA", "code_challenge_method" => "S256" },
                 URI.decode_www_form(parsed.query).to_h)
  end

  # -- credentials file ----------------------------------------------------------

  def test_credentials_roundtrip_keeps_servers_apart
    with_credentials_file do |path|
      ForgeCI::Auth.write_server("https://ci.example.com/", "a" => 1) # trailing slash normalized away
      ForgeCI::Auth.write_server("https://other.example.com", "b" => 2)

      assert_equal({ "a" => 1 }, ForgeCI::Auth.read_server("https://ci.example.com"))
      assert_equal({ "b" => 2 }, ForgeCI::Auth.read_server("https://other.example.com/"))
      assert_nil ForgeCI::Auth.read_server("https://nope.example.com")
      assert_equal 0o600, File.stat(path).mode & 0o777, "credentials are private"
    end
  end

  def test_deleting_the_last_server_removes_the_file
    with_credentials_file do |path|
      ForgeCI::Auth.write_server("https://ci.example.com", "x" => 1)
      assert ForgeCI::Auth.delete_server("https://ci.example.com/"), "URLs normalize before matching"
      refute File.exist?(path)
      refute ForgeCI::Auth.delete_server("https://ci.example.com")
    end
  end

  def test_load_credentials_tolerates_missing_or_corrupt_files
    with_credentials_file do |path|
      assert_equal({}, ForgeCI::Auth.load_credentials)
      File.write(path, "{not json")
      assert_equal({}, ForgeCI::Auth.load_credentials)
      assert_nil ForgeCI::Auth.read_server("https://ci.example.com")
    end
  end

  def test_stored_token_returns_valid_tokens_without_touching_the_server
    with_credentials_file do
      ForgeCI::Auth.write_server("https://ci.example.com",
                                 "access_token" => "at", "expires_at" => Time.now.to_i + 3600)
      assert_equal "at", ForgeCI::Auth.stored_token("https://ci.example.com")
    end
  end

  # -- loopback callback -----------------------------------------------------------

  def test_parse_request_query_extracts_callback_params
    assert_equal({ "code" => "abc", "state" => "s1" },
                 ForgeCI::Auth.parse_request_query("GET /callback?code=abc&state=s1 HTTP/1.1\r\n"))
    assert_equal({}, ForgeCI::Auth.parse_request_query("GET /favicon.ico HTTP/1.1"))
    assert_equal({}, ForgeCI::Auth.parse_request_query(""))
  end

  def test_wait_for_code_skips_stray_requests_and_answers_the_browser
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    code = nil
    waiter = Thread.new { code = ForgeCI::Auth.wait_for_code(server, state: "st4te", deadline: 5) }

    Net::HTTP.get_response("127.0.0.1", "/favicon.ico", port) # stray request, ignored
    response = Net::HTTP.get_response("127.0.0.1", "/callback?code=s3cret&state=st4te", port)
    waiter.join(5)

    assert_equal ["s3cret", "st4te"], code
    assert_equal "200", response.code
  ensure
    server&.close
  end

  def test_wait_for_code_ignores_a_state_mismatch
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    result = nil
    waiter = Thread.new { result = ForgeCI::Auth.wait_for_code(server, state: "good", deadline: 5) }

    Net::HTTP.get_response("127.0.0.1", "/callback?code=hijacked&state=evil", port)
    waiter.join(0.2)
    assert_nil result, "a wrong state must not end the wait"

    Net::HTTP.get_response("127.0.0.1", "/callback?code=real&state=good", port)
    waiter.join(5)
    assert_equal ["real", "good"], result
  ensure
    server&.close
  end

  def test_wait_for_code_reports_authorization_errors
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    waiter = Thread.new do
      error = assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.wait_for_code(server, state: "s", deadline: 5) }
      assert_match(/access_denied/, error.message)
    end
    Net::HTTP.get_response("127.0.0.1", "/callback?error=access_denied", port)
    waiter.join(5)
  ensure
    server&.close
  end

  def test_wait_for_code_times_out
    server = TCPServer.new("127.0.0.1", 0)
    error = assert_raises(ForgeCI::Auth::Error) do
      ForgeCI::Auth.wait_for_code(server, state: "s", deadline: 0.01)
    end
    assert_match(/timed out/, error.message)
  ensure
    server&.close
  end
end
