# frozen_string_literal: true

# Stands in for api.github.com behind the real Github::AppClient, so HTTP
# status handling and retries run end to end. Config fetches answer with
# config_yaml (404 when nil) and status posts with 201, after first replaying
# any queued failures: an HTTP status code, or an exception to raise from the
# socket (a network failure).
class FakeGithub
  Response = Struct.new(:code, :body)

  class Client < Github::AppClient
    def installation_token
      "test-installation-token"
    end
  end

  attr_accessor :use_ssl, :open_timeout, :read_timeout, :on_status_post
  attr_reader :statuses, :status_post_attempts

  def initialize(config_yaml: nil)
    @config_yaml = config_yaml
    @status_failures = []
    @config_failures = []
    @statuses = []
    @status_post_attempts = 0
  end

  def fail_status_posts(*failures)
    @status_failures.concat(failures)
  end

  def fail_config_fetches(*failures)
    @config_failures.concat(failures)
  end

  # Route GitHub API calls made inside the block to this fake.
  def install
    fake = self
    real_new = Net::HTTP.method(:new)
    old_factory = Github.client_factory
    Github.client_factory = ->(id) { Client.new(installation_id: id) }
    Net::HTTP.define_singleton_method(:new) { |*| fake }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, real_new)
    Github.client_factory = old_factory
  end

  # The one Net::HTTP method AppClient calls.
  def request(request)
    case request.path
    when %r{\A/repos/(.+)/statuses/(\w+)\z} then status_post(request, $1, $2)
    when %r{\A/repos/.+/contents/} then config_fetch
    else raise ArgumentError, "unexpected GitHub request #{request.method} #{request.path}"
    end
  end

  private

  def status_post(request, full_name, sha)
    @status_post_attempts += 1
    on_status_post&.call
    replay_failure(@status_failures) || begin
      @statuses << JSON.parse(request.body).merge("full_name" => full_name, "sha" => sha)
      Response.new("201", { "id" => @statuses.size }.to_json)
    end
  end

  def config_fetch
    replay_failure(@config_failures) ||
      if @config_yaml
        Response.new("200", { "encoding" => "base64", "content" => Base64.encode64(@config_yaml) }.to_json)
      else
        Response.new("404", { "message" => "Not Found" }.to_json)
      end
  end

  def replay_failure(failures)
    failure = failures.shift
    return if failure.nil?
    raise failure if failure.is_a?(Exception)

    Response.new(failure.to_s, { "message" => "fake GitHub #{failure}" }.to_json)
  end
end
