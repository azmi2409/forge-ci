# frozen_string_literal: true

module ForgeCI
  # Structural validation of the CircleCI v2.1 subset. Every problem is
  # collected into +errors+ (an ErrorCollector) — nothing is raised — so the
  # caller sees all problems in one pass. Validation runs on the
  # expanded + interpolated config, i.e. after reusable commands/executors
  # have been inlined and << >> references resolved.
  module Validator
    TOP_LEVEL_KEYS = %w[version orbs parameters commands executors jobs workflows].freeze
    SUPPORTED_VERSIONS = %w[2 2.1].freeze

    # Step types we know how to normalize into the IR.
    STEP_TYPES = %w[
      checkout run save_cache restore_cache
      persist_to_workspace attach_workspace
      store_artifacts store_test_results add_ssh_keys
    ].freeze

    # Conditional wrappers evaluated at compile time.
    CONDITIONAL_TYPES = %w[when unless].freeze

    RUN_WHEN_VALUES = %w[on_success on_fail always].freeze
    PARAMETER_TYPES = %w[string boolean integer enum].freeze
    WORKFLOW_JOB_KEYS = %w[requires filters matrix context name].freeze

    module_function

    # --- top level ---------------------------------------------------------

    def top_level(config, errors)
      unknown = config.keys.map(&:to_s) - TOP_LEVEL_KEYS
      unknown.each do |key|
        errors.add([], "unknown top-level key #{key.inspect}; " \
                       "supported keys: #{TOP_LEVEL_KEYS.join(', ')}")
      end

      version = config["version"]
      unless SUPPORTED_VERSIONS.include?(version.to_s)
        errors.add(["version"], "unsupported version #{version.inspect}; expected \"2.1\"")
      end

      if config.key?("orbs") && !config["orbs"].nil? && config["orbs"] != {}
        errors.add(["orbs"], "orb registry is not supported in forge-ci v1; " \
                             "inline the orb's steps/commands into your config instead")
      end

      unless config["jobs"].is_a?(Hash) && !config["jobs"].empty?
        errors.add(["jobs"], "no jobs defined; add at least one job under \"jobs:\"")
      end

      %w[parameters commands executors].each do |key|
        if config.key?(key) && !config[key].nil? && !config[key].is_a?(Hash)
          errors.add([key], "\"#{key}:\" must be a mapping")
        end
      end

      return unless config.key?("workflows") && !config["workflows"].is_a?(Hash)

      errors.add(["workflows"], "\"workflows:\" must be a mapping of workflow name to definition")
    end

    # --- pipeline parameters ------------------------------------------------

    def parameters(params_def, errors)
      return if params_def.nil?

      unless params_def.is_a?(Hash)
        errors.add(["parameters"], "\"parameters:\" must be a mapping of name to definition")
        return
      end

      params_def.each do |name, definition|
        path = ["parameters", name]
        unless definition.is_a?(Hash)
          errors.add(path, "parameter definition must be a mapping with \"type\" (and usually \"default\")")
          next
        end

        type = definition["type"] || "string"
        unless PARAMETER_TYPES.include?(type.to_s)
          errors.add(path + ["type"], "unknown parameter type #{type.inspect}; " \
                                      "expected one of: #{PARAMETER_TYPES.join(', ')}")
          next
        end

        if type.to_s == "enum" && !definition["enum"].is_a?(Array)
          errors.add(path, "enum parameters require an \"enum:\" list of allowed values")
        end

        next unless definition.key?("default")

        default = definition["default"]
        unless value_matches_type?(default, type.to_s)
          errors.add(path + ["default"],
                     "default #{default.inspect} does not match declared type #{type.inspect}")
        end

        if type.to_s == "enum" && definition["enum"].is_a?(Array) && !definition["enum"].include?(default)
          errors.add(path + ["default"],
                     "default #{default.inspect} is not in the enum list #{definition['enum'].inspect}")
        end
      end
    end

    def value_matches_type?(value, type)
      case type
      when "string" then value.is_a?(String)
      when "boolean" then value == true || value == false
      when "integer" then value.is_a?(Integer)
      when "enum" then true # membership checked separately
      else false
      end
    end

    # --- reusable commands / executors --------------------------------------

    def command(name, definition, errors)
      path = ["commands", name]
      unless definition.is_a?(Hash)
        errors.add(path, "command definition must be a mapping with \"steps\" (and optional \"parameters\")")
        return
      end
      parameters(definition["parameters"], errors) if definition.key?("parameters")
      unless definition["steps"].is_a?(Array)
        errors.add(path + ["steps"], "command #{name.inspect} must define a \"steps:\" list")
      end
    end

    def executor_definition(name, definition, errors)
      path = ["executors", name]
      unless definition.is_a?(Hash)
        errors.add(path, "executor definition must be a mapping")
        return
      end
      parameters(definition["parameters"], errors) if definition.key?("parameters")
      docker = definition["docker"]
      unless docker.is_a?(Array) && !docker.empty?
        errors.add(path + ["docker"],
                   "executor #{name.inspect} must define a non-empty \"docker:\" image list (only Docker executors are supported in v1)")
      end
    end

    # --- jobs ---------------------------------------------------------------

    def job(name, job, errors)
      path = ["jobs", name]
      unless job.is_a?(Hash)
        errors.add(path, "job definition must be a mapping")
        return
      end

      docker = job["docker"]
      if docker.nil? || (docker.is_a?(Array) && docker.empty?)
        errors.add(path, "job #{name.inspect} must declare a \"docker:\" executor " \
                         "(or reference one via \"executor:\")")
      elsif !docker.is_a?(Array)
        errors.add(path + ["docker"], "\"docker:\" must be a list of image definitions")
      else
        docker.each_with_index { |img, i| docker_image(img, path + ["docker", i], errors) }
      end

      if job.key?("machine") || job.key?("macos")
        errors.add(path, "only Docker executors are supported in v1; " \
                         "\"machine\"/\"macos\" executors are not available yet")
      end

      steps = job["steps"]
      if !steps.is_a?(Array) || steps.empty?
        errors.add(path + ["steps"], "job #{name.inspect} must define a non-empty \"steps:\" list")
        return
      end
      steps.each_with_index { |step, i| step(step, path + ["steps", i], errors) }

      return unless job.key?("environment") && !job["environment"].is_a?(Hash)

      errors.add(path + ["environment"], "\"environment:\" must be a mapping of variable names to values")
    end

    def docker_image(img, path, errors)
      unless img.is_a?(Hash) && img["image"].is_a?(String) && !img["image"].empty?
        errors.add(path, "each \"docker:\" entry needs an \"image:\" string (e.g. image: cimg/ruby:3.2)")
        return
      end
      return unless img.key?("environment") && !img["environment"].is_a?(Hash)

      errors.add(path + ["environment"], "\"environment:\" must be a mapping")
    end

    # --- steps ----------------------------------------------------------------

    # Validates one step; expects pre-normalized steps (bare `run:` strings
    # already expanded to {command: ...} by the compiler).
    def step(step, path, errors)
      unless step.is_a?(Hash) && step.size == 1
        errors.add(path, "each step must be a mapping with exactly one key " \
                         "(e.g. \"- run:\", \"- checkout:\", or a reusable command name)")
        return
      end

      type, cfg = step.first
      type = type.to_s

      if CONDITIONAL_TYPES.include?(type)
        conditional_step(cfg, path, errors, type)
        return
      end

      unless STEP_TYPES.include?(type)
        errors.add(path, "unknown step type #{type.inspect}; " \
                         "supported steps: #{(STEP_TYPES + CONDITIONAL_TYPES).join(', ')}")
        return
      end

      cfg = {} if cfg.nil?
      unless cfg.is_a?(Hash)
        errors.add(path + [type], "step #{type.inspect} expects a mapping of attributes")
        return
      end

      send("validate_#{type}", cfg, path + [type], errors)
    end

    def conditional_step(cfg, path, errors, type)
      unless cfg.is_a?(Hash) && cfg.key?("condition") && cfg["steps"].is_a?(Array)
        errors.add(path + [type], "\"#{type}:\" needs \"condition:\" and a \"steps:\" list")
        return
      end
      cfg["steps"].each_with_index { |s, i| step(s, path + [type, "steps", i], errors) }
    end

    def validate_checkout(cfg, path, errors)
      return unless cfg.key?("path") && !cfg["path"].is_a?(String)

      errors.add(path + ["path"], "\"path:\" must be a string")
    end

    def validate_run(cfg, path, errors)
      if cfg["command"].nil? || (cfg["command"].is_a?(String) && cfg["command"].strip.empty?)
        errors.add(path, "\"run:\" needs a \"command:\" (or use the \"run: <command>\" shorthand)")
      end
      if cfg.key?("when") && !RUN_WHEN_VALUES.include?(cfg["when"].to_s)
        errors.add(path + ["when"], "\"when:\" must be one of: #{RUN_WHEN_VALUES.join(', ')}")
      end
      if cfg.key?("environment") && !cfg["environment"].is_a?(Hash)
        errors.add(path + ["environment"], "\"environment:\" must be a mapping of variable names to values")
      end
      if cfg.key?("no_output_timeout") && !cfg["no_output_timeout"].to_s.match?(/\A\d+(\.\d+)?[smh]?\z/)
        errors.add(path + ["no_output_timeout"], "\"no_output_timeout:\" must look like 30s, 10m or 1h")
      end
      return unless cfg.key?("background") && ![true, false].include?(cfg["background"])

      errors.add(path + ["background"], "\"background:\" must be true or false")
    end

    def validate_save_cache(cfg, path, errors)
      validate_cache_keys(cfg, path, errors, "save_cache")
      return unless cfg["paths"].nil? || !cfg["paths"].is_a?(Array) || cfg["paths"].empty?

      errors.add(path, "\"save_cache:\" needs a non-empty \"paths:\" list of directories/files to cache")
    end

    def validate_restore_cache(cfg, path, errors)
      validate_cache_keys(cfg, path, errors, "restore_cache")
    end

    def validate_cache_keys(cfg, path, errors, type)
      keys = cfg["keys"] || (cfg.key?("key") ? [cfg["key"]] : nil)
      if !keys.is_a?(Array) || keys.empty? || keys.any? { |k| !k.is_a?(String) || k.empty? }
        errors.add(path, "\"#{type}:\" needs \"keys:\" as a non-empty list of key template strings")
      end
    end

    def validate_persist_to_workspace(cfg, path, errors)
      if cfg["root"].nil? || !cfg["root"].is_a?(String) || cfg["root"].empty?
        errors.add(path, "\"persist_to_workspace:\" needs a \"root:\" directory path")
      end
      return unless cfg["paths"].nil? || !cfg["paths"].is_a?(Array) || cfg["paths"].empty?

      errors.add(path, "\"persist_to_workspace:\" needs a non-empty \"paths:\" list")
    end

    def validate_attach_workspace(cfg, path, errors)
      return if cfg["at"].is_a?(String) && !cfg["at"].empty?

      errors.add(path, "\"attach_workspace:\" needs an \"at:\" directory path")
    end

    def validate_store_artifacts(cfg, path, errors)
      return if cfg["path"].is_a?(String) && !cfg["path"].empty?

      errors.add(path, "\"store_artifacts:\" needs a \"path:\" to the file or directory to upload")
    end

    def validate_store_test_results(cfg, path, errors)
      return if cfg["path"].is_a?(String) && !cfg["path"].empty?

      errors.add(path, "\"store_test_results:\" needs a \"path:\" to the JUnit XML results directory")
    end

    def validate_add_ssh_keys(cfg, path, errors)
      return unless cfg.key?("fingerprints") && !cfg["fingerprints"].is_a?(Array)

      errors.add(path + ["fingerprints"], "\"fingerprints:\" must be a list of SSH key fingerprints")
    end

    # --- workflows ------------------------------------------------------------

    def workflow(name, wf, errors, known_jobs)
      path = ["workflows", name]
      unless wf.is_a?(Hash) && wf["jobs"].is_a?(Array)
        errors.add(path, "workflow #{name.inspect} must define a \"jobs:\" list")
        return
      end

      wf["jobs"].each_with_index do |entry, i|
        job_name, cfg = CompilerEntry.parse(entry)
        entry_path = path + ["jobs", i]

        if job_name.nil?
          errors.add(entry_path, "workflow job entry must be a job name or a mapping of job name to options " \
                                 "(requires/filters/matrix/context)")
          next
        end

        unless known_jobs.include?(job_name)
          errors.add(entry_path, "workflow references unknown job #{job_name.inspect}; " \
                                 "defined jobs: #{known_jobs.sort.join(', ')}")
          next
        end

        unknown = cfg.keys.map(&:to_s) - WORKFLOW_JOB_KEYS
        unknown.each do |key|
          errors.add(entry_path + [job_name], "unknown workflow job option #{key.inspect}; " \
                                              "supported: #{WORKFLOW_JOB_KEYS.join(', ')}")
        end

        if cfg.key?("requires")
          unless cfg["requires"].is_a?(Array) && cfg["requires"].all? { |r| r.is_a?(String) }
            errors.add(entry_path + [job_name, "requires"], "\"requires:\" must be a list of job names")
          end
        end

        validate_filters(cfg["filters"], entry_path + [job_name, "filters"], errors) if cfg.key?("filters")
        validate_matrix(cfg["matrix"], entry_path + [job_name, "matrix"], errors) if cfg.key?("matrix")

        next unless cfg.key?("type")

        errors.add(entry_path + [job_name], "\"type: approval\" jobs are not supported in v1; " \
                                             "every workflow job runs its steps")
      end
    end

    def validate_filters(filters, path, errors)
      unless filters.is_a?(Hash)
        errors.add(path, "\"filters:\" must be a mapping")
        return
      end
      branches = filters["branches"]
      return if branches.nil?

      unless branches.is_a?(Hash)
        errors.add(path + ["branches"], "\"branches:\" must be a mapping with \"only\" and/or \"ignore\" lists")
        return
      end
      %w[only ignore].each do |key|
        next if branches[key].nil?
        next if branches[key].is_a?(Array) && branches[key].all? { |b| b.is_a?(String) }

        errors.add(path + ["branches", key], "\"#{key}:\" must be a list of branch names " \
                                              "(plain names or /regex/ patterns)")
      end
      return unless filters.keys.map(&:to_s) != ["branches"]

      # tags filters etc. are parsed but not honored in v1 — handled by the compiler as a warning.
    end

    def validate_matrix(matrix, path, errors)
      unless matrix.is_a?(Hash)
        errors.add(path, "\"matrix:\" must be a mapping with \"parameters:\"")
        return
      end
      params = matrix["parameters"]
      if !params.is_a?(Hash) || params.empty? || !params.values.all? { |v| v.is_a?(Array) && !v.empty? }
        errors.add(path + ["parameters"], "\"matrix.parameters:\" must map names to non-empty value lists")
      end
      return if !matrix.key?("alias") || matrix["alias"].is_a?(String)

      errors.add(path + ["alias"], "\"matrix.alias:\" must be a string")
    end

    # Parses a workflow "jobs:" entry: either a bare job name String, or a
    # single-key mapping of job name => options hash. Returns [name, options].
    module CompilerEntry
      module_function

      def parse(entry)
        return [entry, {}] if entry.is_a?(String)
        return [nil, {}] unless entry.is_a?(Hash) && entry.size == 1

        name, cfg = entry.first
        cfg = {} if cfg.nil?
        return [nil, {}] unless cfg.is_a?(Hash)

        [name.to_s, cfg]
      end
    end
  end
end
