# frozen_string_literal: true

require "optparse"
require "json"
require "net/http"
require "openssl"
require "uri"
require "open3"
require "fileutils"

require_relative "auth"

module ForgeCI
  # Command-line interface for forge-ci.
  #
  #   forge-ci validate <config.yml>
  #   forge-ci compile <config.yml> [--branch B] [--sha S] [--number N] [--json]
  #   forge-ci --help | --version
  #
  # Kept deliberately thin so it is unit-testable: +run+ takes argv and IO
  # objects and returns an integer exit status instead of calling +exit+
  # itself. exe/forge-ci is just a wrapper that passes ARGV through.
  class CLI
    USAGE = <<~USAGE.freeze
      Usage: forge-ci <command> [options]

      Commands:
        validate <config.yml>                       validate a pipeline config
                                                    (exit 0 if valid, 1 otherwise)
        compile <config.yml> [--branch B] [--sha S]
                [--number N] [--json]               compile a pipeline config to
                                                    its IR as JSON
                                                    (pretty JSON by default,
                                                    --json for compact)
        login [--url URL] [--port N]
              [--manual]                            sign in to a forge-ci server
                                                    in the browser (OAuth); the
                                                    token is stored and picked
                                                    up by trigger/cancel
                                                    (URL defaults to FORGE_CI_URL;
                                                    --manual pastes a code instead
                                                    of waiting on the browser)
        logout [--url URL]                          forget the stored login
        trigger <config.yml> --project P [--url URL] [--token T]
                [--branch B] [--sha S] [--context NAME]... [--wait]
                                                    compile a config and start a
                                                    pipeline on a forge-ci server
                                                    (URL defaults to the
                                                    FORGE_CI_URL env var; the
                                                    token comes from --token,
                                                    FORGE_CI_ADMIN_TOKEN or
                                                    forge-ci login; branch/sha
                                                    default to the current git
                                                    checkout; --wait blocks until
                                                    it finishes and exits 1 if it
                                                    did not succeed)
        cancel <pipeline-id> [--url URL] [--token T]
                                                    cancel a running pipeline
        skill install [--dir DIR] [--force]         install the forge-ci agent
                                                    skill (default DIR:
                                                    .claude/skills, for Claude
                                                    Code in this repository)
        skill show                                  print the skill, e.g. to add
                                                    it to AGENTS.md

      Options:
        -h, --help      show this help and exit
        -v, --version   show the gem version and exit
    USAGE

    # Exit statuses:
    #   0 - success (config valid / compile succeeded / help / version)
    #   1 - the config is invalid, the file could not be read, or the YAML
    #       could not be parsed
    #   2 - CLI usage error (unknown command, bad flags, missing arguments)
    def self.run(argv, out: $stdout, err: $stderr, input: $stdin)
      new(out: out, err: err, input: input).run(argv.dup)
    end

    def initialize(out:, err:, input: $stdin)
      @out = out
      @err = err
      @input = input
    end

    def run(argv)
      command = argv.shift
      case command
      when "validate" then validate_command(argv)
      when "compile" then compile_command(argv)
      when "login" then login_command(argv)
      when "logout" then logout_command(argv)
      when "trigger" then trigger_command(argv)
      when "cancel" then cancel_command(argv)
      when "skill" then skill_command(argv)
      when "-h", "--help", nil then help
      when "-v", "--version" then version
      else usage_error("unknown command #{command.inspect}")
      end
    end

    # The agent skill shipped with the gem (skills/forge-ci/SKILL.md).
    SKILL_SOURCE = File.expand_path("../../skills/forge-ci/SKILL.md", __dir__)

    private

    def help
      @out.puts USAGE
      0
    end

    def version
      @out.puts ForgeCI::VERSION
      0
    end

    def usage_error(message)
      @err.puts "forge-ci: #{message}"
      @err.puts
      @err.puts USAGE
      2
    end

    def read_config(path)
      File.read(path)
    rescue Errno::ENOENT
      @err.puts "forge-ci: #{path}: no such file"
      nil
    rescue SystemCallError, IOError => e
      @err.puts "forge-ci: #{path}: could not read file (#{e.message})"
      nil
    end

    # Prints each error (they already carry YAML line numbers) to stderr.
    # Returns the exit status: 0 when there are no errors, 1 otherwise.
    def report_errors(path, errors)
      if errors.empty?
        @out.puts "forge-ci: #{path}: valid"
        0
      else
        errors.each { |error| @err.puts "forge-ci: #{path}: #{error}" }
        1
      end
    end

    def with_parsed_yaml(path)
      yaml = read_config(path)
      return 1 if yaml.nil?

      yield yaml
    rescue ForgeCI::Error => e
      # The only raise in the library: the YAML could not be parsed at all.
      @err.puts "forge-ci: #{path}: #{e.message}"
      1
    end

    # -- forge-ci validate <config.yml> ------------------------------------

    def validate_command(argv)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci validate <config.yml>"
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end

      path = argv.shift
      return usage_error("validate requires a <config.yml> argument") if path.nil?
      return usage_error("validate takes exactly one <config.yml> argument") unless argv.empty?

      with_parsed_yaml(path) do |yaml|
        report_errors(path, ForgeCI::Compiler.validate(yaml))
      end
    end

    # -- forge-ci compile <config.yml> --------------------------------------

    def compile_command(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci compile <config.yml> " \
                      "[--branch B] [--sha S] [--number N] [--json]"
        opts.on("--branch BRANCH", "pipeline branch; resolves " \
                                   "<< pipeline.git.branch >> and branch filters") do |v|
          options[:branch] = v
        end
        opts.on("--sha SHA", "pipeline git sha (forwarded to the compiler " \
                             "for pipeline context)") do |v|
          options[:sha] = v
        end
        opts.on("--number NUMBER", "pipeline number; resolves " \
                                   "<< pipeline.number >>") do |v|
          options[:number] = v
        end
        opts.on("--json", "emit compact JSON instead of pretty-printed JSON") do
          options[:json] = true
        end
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end

      path = argv.shift
      return usage_error("compile requires a <config.yml> argument") if path.nil?
      return usage_error("compile takes exactly one <config.yml> argument") unless argv.empty?

      pipeline_params = build_pipeline_params(options)

      with_parsed_yaml(path) do |yaml|
        ir, errors = ForgeCI::Compiler.compile(yaml, pipeline_params: pipeline_params)
        if errors.any?
          errors.each { |error| @err.puts "forge-ci: #{path}: #{error}" }
          1
        else
          @out.puts(options[:json] ? JSON.generate(ir) : JSON.pretty_generate(ir))
          0
        end
      end
    end

    # -- forge-ci login / logout -----------------------------------------------

    def login_command(argv)
      options = { url: ENV["FORGE_CI_URL"], port: 0, manual: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci login [--url URL] [--port N] [--manual]"
        opts.on("--url URL", "server base URL (env FORGE_CI_URL)") { |v| options[:url] = v }
        opts.on("--port N", Integer, "loopback port for the browser callback " \
                                     "(default: pick a free one)") { |v| options[:port] = v }
        opts.on("--manual", "print a URL to open elsewhere and paste the code back " \
                            "(no browser, no listener; for SSH)") { options[:manual] = true }
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end
      return usage_error("unexpected argument #{argv.first.inspect}") if argv.any?
      return usage_error("--url (or FORGE_CI_URL) is required") if options[:url].to_s.empty?
      return usage_error("--port must be between 0 and 65535") unless (0..65535).cover?(options[:port])

      begin
        ForgeCI::Auth.login(url: options[:url], out: @out, port: options[:port],
                            manual: options[:manual], input: @input)
        0
      rescue ForgeCI::Auth::Error => e
        @err.puts "forge-ci: #{e.message}"
        1
      end
    end

    def logout_command(argv)
      options = { url: ENV["FORGE_CI_URL"] }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci logout [--url URL]"
        opts.on("--url URL", "server base URL (env FORGE_CI_URL)") { |v| options[:url] = v }
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end
      return usage_error("unexpected argument #{argv.first.inspect}") if argv.any?
      return usage_error("--url (or FORGE_CI_URL) is required") if options[:url].to_s.empty?

      begin
        ForgeCI::Auth.logout(url: options[:url], out: @out)
      rescue ForgeCI::Auth::Error => e
        @err.puts "forge-ci: #{e.message}"
        1
      end
    end

    # -- forge-ci trigger <config.yml> --project P ... ----------------------

    def trigger_command(argv)
      options = { contexts: [], url: ENV["FORGE_CI_URL"], token: ENV["FORGE_CI_ADMIN_TOKEN"], poll: 5 }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci trigger <config.yml> --project P [options]"
        opts.on("--project P", "project id or name on the server") { |v| options[:project] = v }
        opts.on("--url URL", "server base URL (env FORGE_CI_URL)") { |v| options[:url] = v }
        opts.on("--token TOKEN", "bearer token (env FORGE_CI_ADMIN_TOKEN, " \
                                 "or forge-ci login)") { |v| options[:token] = v }
        opts.on("--branch B", "branch (default: current git branch)") { |v| options[:branch] = v }
        opts.on("--sha S", "commit sha (default: current git HEAD)") { |v| options[:sha] = v }
        opts.on("--context NAME", "context to inject (repeatable)") { |v| options[:contexts] << v }
        opts.on("--wait", "wait for the pipeline to finish") { options[:wait] = true }
        opts.on("--poll SECONDS", Integer, "poll interval for --wait (default 5)") { |v| options[:poll] = v }
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end

      path = argv.shift
      return usage_error("trigger requires a <config.yml> argument") if path.nil?
      return usage_error("trigger takes exactly one <config.yml> argument") unless argv.empty?
      return usage_error("--project is required") if options[:project].to_s.empty?

      err = server_options_error(options)
      return usage_error(err) if err

      options[:branch] ||= git_output("rev-parse", "--abbrev-ref", "HEAD")
      options[:sha] ||= git_output("rev-parse", "HEAD")
      if options[:branch].to_s.empty? || options[:sha].to_s.empty?
        return usage_error("could not detect git branch/sha — pass --branch and --sha")
      end

      with_parsed_yaml(path) do |yaml|
        ir, errors = ForgeCI::Compiler.compile(
          yaml, pipeline_params: { "branch" => options[:branch], "sha" => options[:sha] }
        )
        if errors.any?
          errors.each { |error| @err.puts "forge-ci: #{path}: #{error}" }
          next 1
        end

        begin
          project_id = resolve_project_id(options)
          pipeline = api_request(options, :post, "/api/v1/projects/#{project_id}/pipelines",
                                 sha: options[:sha], branch: options[:branch],
                                 ir: JSON.parse(JSON.generate(ir)), contexts: options[:contexts])
          @out.puts "forge-ci: pipeline #{pipeline["id"]} started " \
                    "(#{options[:url].sub(%r{/+\z}, "")}/projects/#{project_id}/pipelines/#{pipeline["id"]})"
          options[:wait] ? wait_for_pipeline(options, pipeline["id"]) : 0
        rescue ApiError => e
          @err.puts "forge-ci: #{e.message}"
          1
        end
      end
    end

    # -- forge-ci cancel <pipeline-id> ----------------------------------------

    def cancel_command(argv)
      options = { url: ENV["FORGE_CI_URL"], token: ENV["FORGE_CI_ADMIN_TOKEN"] }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci cancel <pipeline-id> [--url URL] [--token T]"
        opts.on("--url URL", "server base URL (env FORGE_CI_URL)") { |v| options[:url] = v }
        opts.on("--token TOKEN", "bearer token (env FORGE_CI_ADMIN_TOKEN, or forge-ci login)") { |v| options[:token] = v }
        opts.on("-h", "--help", "show this help and exit") do
          @out.puts opts
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        return usage_error(e.message)
      end

      id = argv.shift
      return usage_error("cancel requires a <pipeline-id> argument") if id.nil?

      err = server_options_error(options)
      return usage_error(err) if err

      pipeline = api_request(options, :post, "/api/v1/pipelines/#{id}/cancel")
      @out.puts "forge-ci: pipeline #{pipeline["id"]} is #{pipeline["status"]}"
      0
    rescue ApiError => e
      @err.puts "forge-ci: #{e.message}"
      1
    end

    class ApiError < StandardError; end

    # --url is always required. The token comes from --token or
    # FORGE_CI_ADMIN_TOKEN (both already folded into options[:token]);
    # otherwise falls back to the stored forge-ci login session, refreshing
    # it when expired.
    def server_options_error(options)
      return "--url (or FORGE_CI_URL) is required" if options[:url].to_s.empty?
      return nil unless options[:token].to_s.empty?

      begin
        options[:token] = ForgeCI::Auth.stored_token(options[:url])
      rescue ForgeCI::Auth::Error => e
        return e.message
      end
      "--token (or FORGE_CI_ADMIN_TOKEN, or forge-ci login) is required" if options[:token].to_s.empty?
    end

    def git_output(*args)
      out, status = Open3.capture2("git", *args, err: File::NULL)
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def resolve_project_id(options)
      return options[:project] if options[:project].match?(/\A\d+\z/)

      projects = api_request(options, :get, "/api/v1/projects")
      match = Array(projects["projects"]).find { |p| p["name"] == options[:project] }
      raise ApiError, "project #{options[:project].inspect} not found on server" unless match

      match["id"]
    end

    def wait_for_pipeline(options, id)
      last = nil
      loop do
        pipeline = api_request(options, :get, "/api/v1/pipelines/#{id}")
        if pipeline["status"] != last
          @out.puts "forge-ci: pipeline #{id}: #{pipeline["status"]}"
          last = pipeline["status"]
        end
        return(pipeline["status"] == "success" ? 0 : 1) unless %w[pending running].include?(pipeline["status"])

        sleep options[:poll]
      end
    end

    def api_request(options, verb, path, body = nil)
      uri = URI.join(options[:url].sub(%r{/+\z}, "") + "/", path.sub(%r{\A/}, ""))
      klass = verb == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri)
      req["Authorization"] = "Bearer #{options[:token]}"
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                open_timeout: 10, read_timeout: 60) { |http| http.request(req) }
      parsed = begin
        JSON.parse(res.body.to_s)
      rescue JSON::ParserError
        {}
      end
      unless res.is_a?(Net::HTTPSuccess)
        detail = Array(parsed["details"]).any? ? ": #{Array(parsed["details"]).join("; ")}" : ""
        raise ApiError, "server returned HTTP #{res.code} for #{verb.to_s.upcase} #{path}: " \
                        "#{parsed["error"] || res.message}#{detail}"
      end
      parsed
    rescue SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
      raise ApiError, "could not reach #{options[:url]}: #{e.message}"
    end

    def build_pipeline_params(options)
      params = {}
      params["branch"] = options[:branch] if options[:branch]
      params["sha"] = options[:sha] if options[:sha]
      params["number"] = coerce_number(options[:number]) if options[:number]
      params
    end

    # Pipeline numbers are integers; keep anything else as-is so the
    # interpolator still substitutes it.
    def coerce_number(value)
      value.match?(/\A\d+\z/) ? Integer(value, 10) : value
    end

    # -- forge-ci skill install|show --------------------------------------------

    def skill_command(argv)
      case argv.shift
      when "show"
        @out.write File.read(SKILL_SOURCE, encoding: "UTF-8")
        0
      when "install" then skill_install(argv)
      else usage_error("skill needs a subcommand: install or show")
      end
    end

    def skill_install(argv)
      options = { dir: File.join(".claude", "skills"), force: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: forge-ci skill install [--dir DIR] [--force]"
        opts.on("--dir DIR", "skills directory (default .claude/skills)") { |v| options[:dir] = v }
        opts.on("--force", "replace an existing forge-ci skill") { options[:force] = true }
      end
      parser.parse!(argv)
      return usage_error("unexpected argument #{argv.first.inspect}") if argv.any?

      target = File.join(options[:dir], "forge-ci", "SKILL.md")
      if File.exist?(target) && !options[:force]
        @err.puts "forge-ci: #{target} already exists; pass --force to replace it " \
                  "(your \"Repository notes\" would be lost)"
        return 1
      end

      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, File.read(SKILL_SOURCE, encoding: "UTF-8"))
      @out.puts "forge-ci: installed the forge-ci skill at #{target}"
      @out.puts "forge-ci: add your repository's rules under \"Repository notes\" at the end"
      0
    rescue OptionParser::ParseError => e
      usage_error(e.message)
    end
  end
end
