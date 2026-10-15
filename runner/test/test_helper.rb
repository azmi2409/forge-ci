# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "forge_ci_runner"
require "socket"
require "json"

def docker_available?
  system("docker info > /dev/null 2>&1")
end

# Minimal fake control plane over a real TCP socket. Routes are stubbed
# per (method, path); every request is recorded for assertions.
# stub_raw serves binary bodies (e.g. signed-URL tarball downloads).
class FakeControlPlane
  Response = Struct.new(:code, :body)
  RawResponse = Struct.new(:code, :content_type, :body)

  def initialize
    @stubs = {}
    @raw_stubs = {}
    @requests = []
    @mutex = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        sock = @server.accept
        Thread.new(sock) { |s| handle(s) }
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  attr_reader :port

  def stub(method, path, code, body)
    @stubs[[method, path]] = Response.new(code, body)
  end

  def stub_raw(method, path, code, content_type, body)
    @raw_stubs[[method, path]] = RawResponse.new(code, content_type, body.b)
  end

  def stub_redirect(method, path, location)
    @raw_stubs[[method, path]] = RawResponse.new("302", location, "".b)
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  def last_request
    requests.last
  end

  def close
    @server.close
    @thread.join(2)
  end

  private

  def handle(sock)
    request_line = sock.gets
    return if request_line.nil?

    method, path, _http = request_line.split(" ")
    headers = {}
    while (line = sock.gets) && line != "\r\n"
      k, v = line.chomp.split(": ", 2)
      headers[k.downcase] = v
    end
    length = headers["content-length"].to_i
    body = length.positive? ? sock.read(length) : ""
    @mutex.synchronize do
      @requests << { method: method, path: path, headers: headers, body: body }
    end

    if (raw = @raw_stubs[[method, path]])
      payload = raw.body
      if raw.code == "302"
        sock.write("HTTP/1.1 302 Found\r\n" \
                   "Location: #{raw.content_type}\r\n" \
                   "Content-Length: 0\r\n" \
                   "Connection: close\r\n\r\n")
      else
        sock.write("HTTP/1.1 #{raw.code} OK\r\n" \
                   "Content-Type: #{raw.content_type}\r\n" \
                   "Content-Length: #{payload.bytesize}\r\n" \
                   "Connection: close\r\n\r\n")
        sock.write(payload)
      end
    else
      stub = @stubs[[method, path]] || Response.new("404", { "error" => "no stub" })
      payload = JSON.generate(stub.body)
      sock.write("HTTP/1.1 #{stub.code} OK\r\n" \
                 "Content-Type: application/json\r\n" \
                 "Content-Length: #{payload.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{payload}")
    end
  rescue StandardError
    nil
  ensure
    sock.close rescue nil
  end
end

def runner_config_for(server)
  ForgeCIRunner::Config.new(
    control_plane_url: "http://127.0.0.1:#{server.port}",
    runner_token: "test-token"
  )
end

def test_payload(overrides = {})
  {
    "id" => 11,
    "name" => "build",
    "working_directory" => "~/project",
    "executor" => {
      "type" => "docker",
      "image" => "cimg/ruby:3.2",
      "resource_class" => "medium",
      "environment" => { "RAILS_ENV" => "test" },
      "secondary_images" => [
        { "image" => "postgres:16", "name" => "db",
          "environment" => { "POSTGRES_PASSWORD" => "pw" } }
      ]
    },
    "steps" => [
      { "type" => "checkout" },
      { "type" => "run", "name" => "Bundle", "command" => "bundle install" }
    ],
    "environment" => { "RAILS_ENV" => "test", "DEPLOY_KEY" => "s3cr3t-long-value" },
    "pipeline" => { "sha" => "abc123", "branch" => "main" }
  }.merge(overrides)
end

def test_config(overrides = {})
  ForgeCIRunner::Config.new(
    **{ control_plane_url: "http://localhost:3000",
        runner_token: "t" }.merge(overrides)
  )
end

class NullClient
  def post_log_chunk(*); end
end

# Executor with docker calls recorded instead of executed.
class RecordingExecutor < ForgeCIRunner::Executor
  attr_reader :commands, :fail_on

  def initialize(*args, fail_on: nil)
    super(*args)
    @commands = []
    @fail_on = fail_on
  end

  def stream_exec(argv)
    @commands << [:stream_exec, argv]
    @fail_on == :exec ? 1 : 0
  end

  private

  def run_docker(*args)
    @commands << [:run_docker, args]
    ["", @fail_on == :docker ? 1 : 0]
  end
end
