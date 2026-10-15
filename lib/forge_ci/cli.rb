# frozen_string_literal: true

require "optparse"
require "json"

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

      Options:
        -h, --help      show this help and exit
        -v, --version   show the gem version and exit
    USAGE

    # Exit statuses:
    #   0 - success (config valid / compile succeeded / help / version)
    #   1 - the config is invalid, the file could not be read, or the YAML
    #       could not be parsed
    #   2 - CLI usage error (unknown command, bad flags, missing arguments)
    def self.run(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv.dup)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      command = argv.shift
      case command
      when "validate" then validate_command(argv)
      when "compile" then compile_command(argv)
      when "-h", "--help", nil then help
      when "-v", "--version" then version
      else usage_error("unknown command #{command.inspect}")
      end
    end

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
  end
end
