# frozen_string_literal: true

require "base64"
require "cgi"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "securerandom"
require "socket"
require "tempfile"
require "timeout"
require "uri"

module ForgeCI
  # `forge-ci login` and the token storage behind it. OAuth 2.0
  # authorization-code + PKCE (S256) against the server's Doorkeeper
  # endpoints: the CLI opens the browser at /oauth/authorize, the user signs
  # in with the web UI, and the redirect back to a loopback port hands the
  # CLI a code it exchanges for an access/refresh token pair.
  #
  # Tokens live in a JSON file (0600) under ~/.config/forge-ci — one entry
  # per server, so one machine can talk to several forges. `--token` /
  # FORGE_CI_ADMIN_TOKEN always win over the stored session (see CLI).
  # stdlib only, like the rest of the gem.
  module Auth
    CLIENT_ID = "forge-ci-cli"
    CALLBACK_PATH = "/callback"
    # Fallback for --manual (SSH/headless): Doorkeeper shows the code on a
    # page the user copies back into the terminal.
    OOB_REDIRECT_URI = "urn:ietf:wg:oauth:2.0:oob"
    CALLBACK_TIMEOUT = 300

    class Error < StandardError; end

    module_function

    def normalize_url(url)
      stripped = url.to_s.strip.sub(%r{/+\z}, "")
      raise Error, "server URL required" if stripped.empty?

      uri = URI.parse(stripped)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
        raise Error, "server URL must be an HTTP(S) URL without credentials, query, or fragment"
      end
      stripped
    rescue URI::InvalidURIError
      raise Error, "invalid server URL"
    end

    # -- PKCE (RFC 7636) -------------------------------------------------------

    def generate_verifier
      SecureRandom.urlsafe_base64(64) # 86 chars: within the 43..128 range
    end

    def code_challenge(verifier)
      Base64.urlsafe_encode64(OpenSSL::Digest::SHA256.digest(verifier), padding: false)
    end

    def authorize_url(url:, redirect_uri:, challenge:, state:, scope: "api")
      query = URI.encode_www_form(
        client_id: CLIENT_ID, redirect_uri: redirect_uri, response_type: "code",
        scope: scope, state: state, code_challenge: challenge,
        code_challenge_method: "S256"
      )
      "#{normalize_url(url)}/oauth/authorize?#{query}"
    end

    # -- credentials file --------------------------------------------------------

    # FORGE_CI_CREDENTIALS overrides the path (tests, CI, multiple profiles);
    # otherwise XDG_CONFIG_HOME or ~/.config.
    def credentials_path(env = ENV)
      override = env["FORGE_CI_CREDENTIALS"].to_s.strip
      return override unless override.empty?

      config = env["XDG_CONFIG_HOME"].to_s.strip
      config = File.join(env["HOME"].to_s.empty? ? Dir.home : env["HOME"], ".config") if config.empty?
      File.join(config, "forge-ci", "credentials.json")
    end

    # { "servers" => { "https://ci.example.com" => { "username" => ...,
    #   "access_token" => ..., "refresh_token" => ..., "expires_at" => ... } } }
    def read_server(url, env = ENV)
      entry = load_credentials(env).fetch("servers", {})[normalize_url(url)]
      entry.is_a?(Hash) ? entry : nil
    end

    def write_server(url, entry, env = ENV)
      path = credentials_path(env)
      data = load_credentials(env)
      data["servers"] ||= {}
      data["servers"][normalize_url(url)] = entry
      save_credentials(path, data)
    end

    # Removes the server's entry; true when there was one.
    def delete_server(url, env = ENV)
      data = load_credentials(env)
      key = normalize_url(url)
      return false unless data["servers"]&.key?(key)

      data["servers"].delete(key)
      path = credentials_path(env)
      if data["servers"].empty? && data.keys == %w[servers]
        FileUtils.rm_f(path)
      else
        save_credentials(path, data)
      end
      true
    end

    def save_credentials(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create([".credentials", ".json"], File.dirname(path)) do |file|
        file.write(JSON.pretty_generate(data))
        file.flush
        File.rename(file.path, path)
      end
    rescue SystemCallError => e
      raise Error, "could not save credentials: #{e.message}"
    end

    def load_credentials(env = ENV)
      parsed = JSON.parse(File.read(credentials_path(env)))
      unless parsed.is_a?(Hash) && (!parsed.key?("servers") || parsed["servers"].is_a?(Hash))
        raise Error, "invalid credentials file structure"
      end
      parsed
    rescue Errno::ENOENT
      {}
    rescue SystemCallError, JSON::ParserError => e
      raise Error, "could not read credentials: #{e.message}"
    end

    # -- the login flow ------------------------------------------------------------

    # Runs the whole flow and prints progress to +out+. Raises Error on any
    # failure. Options: :manual prints a URL and reads the pasted code from
    # :input instead of listening on loopback and opening the browser; :port
    # pins the loopback port; :launch/:wait exist for tests.
    def login(url:, out:, manual: false, port: 0, input: $stdin, launch: method(:open_in_browser),
              deadline: CALLBACK_TIMEOUT)
      url = normalize_url(url)
      verifier = generate_verifier
      state = SecureRandom.urlsafe_base64(16)
      challenge = code_challenge(verifier)

      if manual
        redirect_uri = OOB_REDIRECT_URI
        target = authorize_url(url: url, redirect_uri: redirect_uri, challenge: challenge, state: state)
        out.puts "Open this URL, sign in, and copy the authorization code it shows:"
        out.puts
        out.puts "  #{target}"
        out.puts
        out.print "Authorization code: "
        code = input.gets.to_s.strip
        raise Error, "no authorization code entered" if code.empty?
      else
        server = TCPServer.new("127.0.0.1", port)
        redirect_uri = "http://127.0.0.1:#{server.addr[1]}#{CALLBACK_PATH}"
        target = authorize_url(url: url, redirect_uri: redirect_uri, challenge: challenge, state: state)
        out.puts "Waiting for the sign-in in your browser…"
        out.puts
        out.puts "  #{target}"
        out.puts
        # Listen before launching: the opener may itself block on the
        # callback response (curl-style launchers, tests).
        waiter = Thread.new { wait_for_code(server, state: state, deadline: deadline) }
        launch.call(target)
        code, _state = waiter.value
      end

      token = exchange_code(url: url, code: code, redirect_uri: redirect_uri, verifier: verifier)
      entry = {
        "username" => nil,
        "access_token" => token["access_token"],
        "refresh_token" => token["refresh_token"],
        "expires_at" => Time.now.to_i + token["expires_in"].to_i
      }
      me = request_json(url, :get, "/api/v1/me", token: entry["access_token"])
      entry["username"] = me["username"] if me["username"]
      write_server(url, entry)
      out.puts "forge-ci: logged in#{entry["username"] ? " as #{entry["username"]}" : ""} (#{url})"
      entry
    ensure
      waiter&.kill
      waiter&.join
      server&.close
    end

    # GET/POST helper for the JSON API. Returns the parsed body; raises
    # Error on transport failures and non-2xx responses.
    def request_json(url, verb, path, form: nil, token: nil)
      uri = URI.join("#{normalize_url(url)}/", path.sub(%r{\A/}, ""))
      request = Net::HTTP.const_get(verb == :get ? :Get : :Post).new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}" if token
      request.set_form_data(form) if form
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                 open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
      body = begin
        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, "server returned invalid JSON for #{verb.to_s.upcase} #{path}" if response.is_a?(Net::HTTPSuccess)
        {}
      end
      if response.is_a?(Net::HTTPSuccess)
        raise Error, "server returned a non-object JSON response for #{verb.to_s.upcase} #{path}" unless body.is_a?(Hash)
        return body
      end

      detail = body.is_a?(Hash) ? (body["error_description"] || body["error"]) : nil
      raise Error, "server returned HTTP #{response.code} for #{verb.to_s.upcase} #{path}#{detail ? ": #{detail}" : ""}"
    rescue SystemCallError, SocketError, IOError, Net::HTTPBadResponse, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise Error, "could not reach #{url}: #{e.message}"
    end

    def exchange_code(url:, code:, redirect_uri:, verifier:)
      body = request_json(url, :post, "/oauth/token",
                          form: { grant_type: "authorization_code", code: code, client_id: CLIENT_ID,
                                  redirect_uri: redirect_uri, code_verifier: verifier })
      raise Error, "the server granted no access token" if body["access_token"].to_s.empty?

      body
    end

    # Accepts the browser's redirect on the loopback server. Ignores stray
    # requests (favicons, prefetch); returns the code once state matches.
    def wait_for_code(server, state:, deadline: CALLBACK_TIMEOUT)
      deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + deadline
      loop do
        remaining = deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "timed out waiting for the browser" if remaining <= 0

        next unless IO.select([server], nil, nil, remaining)

        socket = server.accept
        remaining = deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "timed out waiting for the browser" if remaining <= 0
        line = Timeout.timeout(remaining, Error, "timed out waiting for the browser") { socket.gets(8192) }
        params = parse_request_query(line.to_s)
        if params["error"] && params["state"] == state
          respond_once(socket, 400, "forge-ci: authorization failed: #{params["error_description"] || params["error"]}")
          raise Error, "authorization failed: #{params["error_description"] || params["error"]}"
        end
        if !params["code"].to_s.empty? && params["state"] == state
          respond_once(socket, 200,
                       "Signed in. You can close this window and return to the terminal.")
          return [params["code"], params["state"]]
        end
        respond_once(socket, 404, "Not found")
      ensure
        socket&.close unless socket&.closed?
      end
    end

    # "GET /callback?code=a&state=b HTTP/1.1" → { "code" => "a", "state" => "b" }
    def parse_request_query(request_line)
      method, target, version = request_line.split(" ")
      return {} unless method == "GET" && target&.split("?", 2)&.first == CALLBACK_PATH && version&.start_with?("HTTP/")

      URI.decode_www_form(target.split("?", 2)[1].to_s).to_h
    rescue ArgumentError
      {}
    end

    def respond_once(socket, status, message)
      body = "<!doctype html><title>forge-ci</title><body style=\"font-family: system-ui; " \
             "text-align: center; margin-top: 3rem\">#{CGI.escapeHTML(message)}</body>"
      socket.write "HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'X'}\r\n" \
                   "Content-Type: text/html; charset=utf-8\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    ensure
      socket.close
    end

    def open_in_browser(url)
      case RUBY_PLATFORM
      when /mswin|mingw|windows/ then system("cmd", "/c", "start", "", url.to_s, out: File::NULL, err: File::NULL)
      when /darwin/ then system("open", url.to_s, out: File::NULL, err: File::NULL)
      else system("xdg-open", url.to_s, out: File::NULL, err: File::NULL)
      end
    end

    # -- token resolution for trigger/cancel ---------------------------------------

    # The stored access token for +url+ (nil when not logged in), refreshing
    # it when expired. Raises Error when the server refuses the refresh.
    def stored_token(url, env = ENV)
      entry = read_server(url, env)
      return nil unless entry

      return entry["access_token"] unless expired?(entry)

      refreshed = refresh!(url, entry)
      write_server(url, refreshed, env)
      refreshed["access_token"]
    end

    def expired?(entry, now = Time.now.to_i)
      expires_at = entry["expires_at"].to_i
      expires_at.zero? || now >= expires_at - 30 # renew a little early
    end

    def refresh!(url, entry)
      refresh_token = entry["refresh_token"].to_s
      raise Error, "stored session expired — run forge-ci login" if refresh_token.empty?

      body = request_json(url, :post, "/oauth/token",
                          form: { grant_type: "refresh_token", refresh_token: refresh_token,
                                  client_id: CLIENT_ID })
      raise Error, "the server granted no access token — run forge-ci login" if body["access_token"].to_s.empty?

      entry.merge("access_token" => body["access_token"],
                  "refresh_token" => body["refresh_token"] || refresh_token,
                  "expires_at" => Time.now.to_i + body["expires_in"].to_i)
    end

    # -- logout ----------------------------------------------------------------------

    # Revokes the stored token server-side (best effort) and forgets it.
    # Returns [status, message]; network failures still drop the local
    # credentials — a dead server must not keep the file alive.
    def logout(url:, out:)
      url = normalize_url(url)
      entry = read_server(url)
      if entry.nil?
        out.puts "forge-ci: not logged in to #{url}"
        return 0
      end

      begin
        request_json(url, :post, "/oauth/revoke",
                     form: { token: entry["refresh_token"] || entry["access_token"], client_id: CLIENT_ID })
      rescue Error => e
        out.puts "forge-ci: could not revoke the token on the server (#{e.message}); forgetting it anyway"
      end
      delete_server(url)
      out.puts "forge-ci: logged out (#{url})"
      0
    end
  end
end
