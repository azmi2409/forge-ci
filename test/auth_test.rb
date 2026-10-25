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

  def with_auth_server(body, status: 200)
    server = TCPServer.new("127.0.0.1", 0)
    socket = nil
    requests = []
    thread = Thread.new do
      loop do
        socket = server.accept
        request_line = socket.gets.to_s
        headers = {}
        while (line = socket.gets) && line != "\r\n"
          key, value = line.split(": ", 2)
          headers[key.downcase] = value.to_s.strip
        end
        form = headers["content-length"] ? socket.read(headers["content-length"].to_i) : ""
        verb, path = request_line.split
        requests << { verb: verb, path: path, form: URI.decode_www_form(form).to_h }
        if body
          socket.write "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
        end
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    thread&.kill
    thread&.join
    socket&.close
    server&.close
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

  def test_credentials_errors_preserve_existing_data
    with_credentials_file do |path|
      assert_equal({}, ForgeCI::Auth.load_credentials)
      ["{not json", "[]", '{"servers":[]}'].each do |contents|
        File.write(path, contents)
        assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.load_credentials }
        assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.write_server("https://ci.example.com", "access_token" => "new") }
        assert_equal contents, File.read(path)
      end
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
    assert_equal({}, ForgeCI::Auth.parse_request_query("GET /other?code=abc&state=s1 HTTP/1.1"))
    assert_equal({}, ForgeCI::Auth.parse_request_query("POST /callback?code=abc&state=s1 HTTP/1.1"))
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
    response = Net::HTTP.get_response("127.0.0.1", "/callback?error=access_denied&state=evil", port)
    assert_equal "404", response.code
    response = Net::HTTP.get_response("127.0.0.1", "/callback?code=&state=good", port)
    assert_equal "404", response.code
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
    response = Net::HTTP.get_response("127.0.0.1", "/callback?error=access_denied&state=s&error_description=%3Cscript%3Eaccess_denied%3C%2Fscript%3E", port)
    assert_includes response.body, "&lt;script&gt;"
    refute_includes response.body, "<script>"
    waiter.value
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

  def test_callback_deadline_includes_partial_request_line
    server = TCPServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.addr[1])
    client.write("GET /callback")
    error = assert_raises(ForgeCI::Auth::Error) do
      ForgeCI::Auth.wait_for_code(server, state: "s", deadline: 0.05)
    end
    assert_match(/timed out/, error.message)
  ensure
    client&.close
    server&.close
  end

  def test_server_url_rejects_non_http_and_ambiguous_targets
    ["example.com", "file:///tmp/server", "https://user:secret@example.com", "https://example.com?q=1", "https://example.com#fragment", "http://["].each do |url|
      assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.normalize_url(url) }
    end
    assert_equal "https://example.com/forge", ForgeCI::Auth.normalize_url(" https://example.com/forge/ ")
  end

  def test_credentials_replacement_is_private_and_does_not_follow_symlinks
    with_credentials_file do |path|
      target = "#{path}.target"
      File.write(target, '{"servers":{}}')
      File.symlink(target, path)
      ForgeCI::Auth.write_server("https://ci.example.com", "access_token" => "secret")
      assert_equal '{"servers":{}}', File.read(target)
      refute File.symlink?(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
      ForgeCI::Auth.write_server("https://other.example.com", "access_token" => "other")
      File.chmod(0o644, path)
      ForgeCI::Auth.delete_server("https://other.example.com")
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_transport_rejects_invalid_success_payloads_and_wraps_eof
    ["not json", "[]", "null", nil].each do |body|
      with_auth_server(body) do |url, _requests|
        assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.request_json(url, :get, "/api/v1/me") }
      end
    end
  end

  def test_refresh_persists_rotated_tokens_and_keeps_other_servers
    with_credentials_file do
      body = JSON.generate(access_token: "new", refresh_token: "rotated", expires_in: 3600)
      with_auth_server(body) do |url, requests|
        ForgeCI::Auth.write_server(url, "access_token" => "old", "refresh_token" => "refresh", "expires_at" => 1)
        ForgeCI::Auth.write_server("https://other.example.com", "access_token" => "other")
        assert_equal "new", ForgeCI::Auth.stored_token(url)
        assert_equal "POST", requests.first[:verb]
        assert_equal "/oauth/token", requests.first[:path]
        assert_equal "refresh", requests.first[:form]["refresh_token"]
        assert_equal "refresh_token", requests.first[:form]["grant_type"]
        assert_equal "rotated", ForgeCI::Auth.read_server(url)["refresh_token"]
        assert_equal "other", ForgeCI::Auth.read_server("https://other.example.com")["access_token"]
      end
    end
  end

  def test_logout_revokes_refresh_token_and_forgets_credentials_on_failure
    with_credentials_file do |path|
      with_auth_server('{"error":"unavailable"}', status: 503) do |url, requests|
        ForgeCI::Auth.write_server(url, "access_token" => "access", "refresh_token" => "refresh")
        assert_equal 0, ForgeCI::Auth.logout(url: url, out: StringIO.new)
        assert_equal "/oauth/revoke", requests.first[:path]
        assert_equal "refresh", requests.first[:form]["token"]
        refute File.exist?(path)
      end
    end
  end

  def test_failed_refresh_preserves_stored_credentials
    with_credentials_file do |path|
      with_auth_server('{"error":"invalid_grant"}', status: 400) do |url, _requests|
        ForgeCI::Auth.write_server(url, "access_token" => "old", "refresh_token" => "refresh", "expires_at" => 1)
        original = File.read(path)
        assert_raises(ForgeCI::Auth::Error) { ForgeCI::Auth.stored_token(url) }
        assert_equal original, File.read(path)
      end
    end
  end

  def test_refresh_keeps_existing_refresh_token_when_server_does_not_rotate
    with_auth_server('{"access_token":"new","expires_in":3600}') do |url, _requests|
      entry = ForgeCI::Auth.refresh!(url, "refresh_token" => "existing")
      assert_equal "existing", entry["refresh_token"]
      assert_equal "new", entry["access_token"]
    end
  end
end
