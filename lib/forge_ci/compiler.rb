# frozen_string_literal: true

module ForgeCI
  # The config compiler: YAML text in, normalized IR out.
  #
  #   ir, errors = ForgeCI::Compiler.compile(yaml_text, pipeline_params: {...})
  #   errors     = ForgeCI::Compiler.validate(yaml_text)
  #
  # pipeline_params (all optional, string or symbol keys):
  #   "branch"     -> resolves << pipeline.git.branch >> and branch filters
  #   "number"     -> resolves << pipeline.number >>
  #   "parameters" -> Hash overriding top-level `parameters:` defaults
  #
  # compile returns [ir, errors]. errors is empty on success; ir is nil when
  # errors is non-empty. ForgeCI::Error is raised only when the YAML text
  # cannot be parsed at all.
  class Compiler
    def self.compile(yaml_text, pipeline_params: {})
      new.compile(yaml_text, pipeline_params: pipeline_params)
    end

    def self.validate(yaml_text)
      new.validate(yaml_text)
    end

    def compile(yaml_text, pipeline_params: {})
      pp = normalize_pipeline_params(pipeline_params)
      doc = parse_document(yaml_text)
      errors = ErrorCollector.new(LineIndex.new(doc))
      warnings = []

      config = doc.to_ruby
      unless config.is_a?(Hash)
        errors.add([], "config root must be a mapping of top-level keys (got #{ruby_type(config)})")
        return [nil, errors.to_a]
      end

      Validator.top_level(config, errors)
      Validator.parameters(config["parameters"], errors)
      each_mapping(config, "commands") { |n, d| Validator.command(n, d, errors) }
      each_mapping(config, "executors") { |n, d| Validator.executor_definition(n, d, errors) }
      return [nil, errors.to_a] if errors.any?

      prenormalize_all_steps(config)
      expand_commands(config, errors)
      expand_executors(config, errors)
      return [nil, errors.to_a] if errors.any?

      param_values = resolve_parameters(config["parameters"], pp["parameters"], errors, warnings)
      ctx = {
        "parameters" => param_values,
        "pipeline" => { "branch" => pp["branch"], "number" => pp["number"] },
        "matrix" => {}
      }

      # Pipeline values that were not supplied (e.g. no branch) are left
      # unresolved with a warning instead of failing the compile — the
      # runner resolves them at execution time.
      on_missing = lambda do |ref, path|
        hint = ref == "pipeline.git.branch" ? "\"branch\"" : "\"number\""
        warnings << "#{path.join('.')}: no value supplied for << #{ref} >>; " \
                    "pass #{hint} in pipeline_params to resolve it"
        "<< #{ref} >>"
      end

      # Global interpolation. Matrix references are intentionally left alone
      # here; they resolve per matrix job during the workflow pass.
      config["jobs"] = Interpolator.interpolate(config["jobs"], ctx, errors, ["jobs"],
                                                skip_prefixes: ["matrix."], on_missing: on_missing)
      config["workflows"] = Interpolator.interpolate(config["workflows"], ctx, errors, ["workflows"],
                                                     skip_prefixes: ["matrix."], on_missing: on_missing)
      return [nil, errors.to_a] if errors.any?

      known_jobs = Array(config["jobs"]).to_h.keys.map(&:to_s)
      Array(config["jobs"]).to_h.each { |n, j| Validator.job(n.to_s, j, errors) }
      Array(config["workflows"]).to_h.each { |n, w| Validator.workflow(n.to_s, w, errors, known_jobs) }
      return [nil, errors.to_a] if errors.any?

      workflows_ir = build_workflows(config, errors, ctx, warnings, on_missing)
      return [nil, errors.to_a] if errors.any?

      [IR.document(config["version"], workflows_ir, warnings), []]
    end

    def validate(yaml_text)
      _ir, errors = compile(yaml_text, pipeline_params: {})
      errors
    end

    private

    def normalize_pipeline_params(pp)
      pp = (pp || {}).transform_keys(&:to_s)
      {
        "branch" => pp["branch"],
        "number" => pp["number"],
        "parameters" => (pp["parameters"] || {}).transform_keys(&:to_s)
      }
    end

    def parse_document(yaml_text)
      Psych.parse(yaml_text)
    rescue Psych::SyntaxError => e
      raise Error, "could not parse YAML: #{e.message}"
    end

    def ruby_type(obj)
      obj.nil? ? "nothing (empty file?)" : obj.class.name
    end

    def each_mapping(config, key)
      value = config[key]
      return if value.nil?
      return unless value.is_a?(Hash) # type error already reported by top_level

      value.each { |name, definition| yield(name.to_s, definition) }
    end

    # --- step pre-normalization ------------------------------------------------

    # Accepts the common shorthand forms before validation:
    #   - run: echo hi        ->  - run: {command: "echo hi"}
    #   - checkout:           ->  - checkout: {}
    def prenormalize_all_steps(config)
      each_mapping(config, "commands") do |_name, definition|
        next unless definition.is_a?(Hash) && definition["steps"].is_a?(Array)

        definition["steps"] = prenormalize_steps(definition["steps"])
      end
      each_mapping(config, "jobs") do |_name, job|
        next unless job.is_a?(Hash) && job["steps"].is_a?(Array)

        job["steps"] = prenormalize_steps(job["steps"])
      end
    end

    def prenormalize_steps(steps)
      steps.map do |step|
        # Bare `- checkout` parses as the String "checkout", not a mapping.
        if step.is_a?(String)
          { step => {} }
        elsif step.is_a?(Hash) && step.size == 1
          type, cfg = step.first
          case type.to_s
          when "run" then cfg.is_a?(String) ? { "run" => { "command" => cfg } } : step
          when "checkout" then cfg.nil? ? { "checkout" => {} } : step
          else step
          end
        else
          step
        end
      end
    end

    # --- reusable commands -----------------------------------------------------

    # Inlines `commands:` call sites. A step whose single key matches a
    # command name is replaced by the command's steps, with
    # << parameters.x >> substituted from the call-site overrides (or the
    # command parameter defaults). References to anything else are left for
    # the global interpolation pass.
    def expand_commands(config, errors)
      commands = config["commands"]
      return unless commands.is_a?(Hash)

      each_mapping(config, "jobs") do |job_name, job|
        next unless job.is_a?(Hash) && job["steps"].is_a?(Array)

        path = ["jobs", job_name, "steps"]
        expanded = []
        job["steps"].each_with_index do |step, i|
          expanded.concat(expand_step(step, commands, errors, path + [i], 0))
        end
        job["steps"] = expanded
      end
    end

    def expand_step(step, commands, errors, path, depth)
      if depth > 10
        errors.add(path, "command expansion exceeded 10 levels; check for recursive command calls")
        return [step]
      end
      return [step] unless step.is_a?(Hash) && step.size == 1

      key, value = step.first
      key = key.to_s
      return [step] unless commands.key?(key)

      definition = commands[key]
      params_def = (definition.is_a?(Hash) && definition["parameters"]) || {}
      unless value.nil? || value.is_a?(Hash)
        errors.add(path, "arguments to command #{key.inspect} must be a mapping of parameter names to values")
        return [step]
      end
      overrides = (value || {}).transform_keys(&:to_s)

      values = resolve_call_params(params_def, overrides, errors, path, "command #{key.inspect}")
      steps = deep_dup(definition["steps"] || [])
      local_ctx = { "parameters" => values, "pipeline" => {}, "matrix" => {} }
      only = values.keys.map { |name| "parameters.#{name}" }
      steps = Interpolator.interpolate(steps, local_ctx, errors, path, only: only)
      steps.flat_map { |s| expand_step(s, commands, errors, path, depth + 1) }
    end

    def resolve_call_params(params_def, overrides, errors, path, owner)
      params_def = params_def.is_a?(Hash) ? params_def : {}
      unknown = overrides.keys - params_def.keys.map(&:to_s)
      unknown.each { |u| errors.add(path, "#{owner} has no parameter #{u.inspect}") }

      values = {}
      params_def.each do |pname, pdef|
        pname = pname.to_s
        if overrides.key?(pname)
          values[pname] = overrides[pname]
        elsif pdef.is_a?(Hash) && pdef.key?("default")
          values[pname] = pdef["default"]
        else
          errors.add(path, "#{owner} requires parameter #{pname.inspect} but no value was given")
        end
      end
      values
    end

    # --- reusable executors ----------------------------------------------------

    # Resolves `executor:` references on jobs. Supports both forms:
    #   executor: my-executor
    #   executor: {name: my-executor, ruby_version: "3.2"}
    # Job-level keys win over the executor definition (environment maps merge).
    def expand_executors(config, errors)
      executors = config["executors"]
      return unless executors.is_a?(Hash)

      each_mapping(config, "jobs") do |job_name, job|
        next unless job.is_a?(Hash)

        path = ["jobs", job_name]
        ref = job["executor"]
        next if ref.nil?

        if job.key?("docker")
          errors.add(path, "job #{job_name.inspect} declares both \"docker:\" and \"executor:\"; use one")
          next
        end

        name, overrides = parse_executor_ref(ref, errors, path + ["executor"])
        next if name.nil?

        definition = executors[name]
        if definition.nil?
          errors.add(path + ["executor"], "unknown executor #{name.inspect}; " \
                                          "defined executors: #{executors.keys.map(&:to_s).sort.join(', ')}")
          next
        end

        values = resolve_call_params(definition["parameters"], overrides, errors, path + ["executor"], "executor #{name.inspect}")
        expanded = deep_dup(definition)
        expanded.delete("parameters")
        only = values.keys.map { |pname| "parameters.#{pname}" }
        expanded = Interpolator.interpolate(expanded, { "parameters" => values, "pipeline" => {}, "matrix" => {} },
                                            errors, path + ["executor"], only: only)

        expanded.each do |key, value|
          if key == "environment" && job["environment"].is_a?(Hash) && value.is_a?(Hash)
            job["environment"] = value.merge(job["environment"])
          elsif !job.key?(key)
            job[key] = value
          end
        end
        job.delete("executor")
      end
    end

    def parse_executor_ref(ref, errors, path)
      case ref
      when String
        [ref, {}]
      when Hash
        if ref.size == 1 && !ref.key?("name")
          name, params = ref.first
          [name.to_s, params.is_a?(Hash) ? params.transform_keys(&:to_s) : {}]
        elsif ref["name"]
          [ref["name"].to_s, ref.reject { |k, _| k.to_s == "name" }.transform_keys(&:to_s)]
        else
          errors.add(path, "\"executor:\" mapping needs a \"name:\" key")
          [nil, {}]
        end
      else
        errors.add(path, "\"executor:\" must be an executor name or a mapping with \"name:\"")
        [nil, {}]
      end
    end

    # --- pipeline parameters ---------------------------------------------------

    def resolve_parameters(params_def, overrides, errors, warnings)
      params_def = params_def.is_a?(Hash) ? params_def : {}
      unknown = overrides.keys - params_def.keys.map(&:to_s)
      unknown.each do |name|
        warnings << "pipeline_params references unknown parameter #{name.inspect}; ignored"
      end

      values = {}
      params_def.each do |name, definition|
        name = name.to_s
        type = (definition.is_a?(Hash) && definition["type"] || "string").to_s
        if overrides.key?(name)
          value = overrides[name]
          unless Validator.value_matches_type?(value, type)
            errors.add(["parameters", name],
                       "override value #{value.inspect} does not match declared type #{type.inspect}")
            next
          end
          values[name] = value
        elsif definition.is_a?(Hash) && definition.key?("default")
          values[name] = definition["default"]
        else
          errors.add(["parameters", name],
                     "parameter #{name.inspect} has no default and no value was supplied via pipeline_params")
        end
      end
      values
    end

    # --- workflows ---------------------------------------------------------------

    def build_workflows(config, errors, ctx, warnings, on_missing)
      workflows_cfg = config["workflows"]
      jobs_def = config["jobs"] || {}

      if !workflows_cfg.is_a?(Hash) || workflows_cfg.empty?
        warnings << "no \"workflows:\" defined; running all jobs in a single implicit \"default\" workflow"
        names = jobs_def.keys.map(&:to_s)
        return [IR.workflow("default", names.map { |n| build_job_ir(n, n, {}, jobs_def, errors, ctx, on_missing) })]
      end

      workflows_cfg.map do |wf_name, wf|
        build_workflow(wf_name.to_s, wf, jobs_def, errors, ctx, warnings, on_missing)
      end.compact
    end

    def build_workflow(wf_name, wf, jobs_def, errors, ctx, warnings, on_missing)
      branch = ctx["pipeline"]["branch"]

      # 1. Expand matrix entries into concrete job instances.
      instances = [] # [instance_name, base_job_name, entry_cfg, matrix_values]
      sources = Hash.new { |h, k| h[k] = [] } # base name or matrix alias -> [instance names]
      (wf["jobs"] || []).each_with_index do |entry, i|
        job_name, cfg = Validator::CompilerEntry.parse(entry)
        path = ["workflows", wf_name, "jobs", i]

        if cfg["matrix"]
          combos = matrix_combinations(cfg["matrix"]["parameters"] || {})
          combos.each_with_index do |combo, idx|
            inst = "#{job_name}-#{idx}"
            instances << [inst, job_name, cfg, combo]
            sources[job_name] << inst
            sources[cfg["matrix"]["alias"].to_s] << inst if cfg["matrix"]["alias"]
          end
        else
          instances << [job_name, job_name, cfg, {}]
          sources[job_name] << job_name
        end

        if (filters = cfg["filters"]) && filters.is_a?(Hash)
          extra = filters.keys.map(&:to_s) - ["branches"]
          unless extra.empty?
            warnings << "workflows.#{wf_name}: only \"branches\" filters are supported in v1; " \
                        "#{extra.map(&:inspect).join(', ')} on job #{job_name.inspect} will be ignored"
          end
        end
      end

      seen = {}
      instances.each do |inst, _base, _cfg, _combo|
        if seen[inst]
          errors.add(["workflows", wf_name], "job #{inst.inspect} appears more than once in the workflow")
        end
        seen[inst] = true
      end
      return nil if errors.any?

      # 2. Branch filters decide which instances are active.
      active = {}
      instances.each do |inst, _base, cfg, _combo|
        filters = cfg["filters"] || {}
        if filters["branches"] && branch.nil?
          warnings << "no branch supplied via pipeline_params; branch filters for job #{inst.inspect} not applied"
          active[inst] = true
        else
          active[inst] = branch_matches?(filters, branch)
        end
      end

      # 3. Resolve requires edges (names and matrix aliases both work).
      edges = {}
      instances.each_with_index do |(inst, _base, cfg, _combo), i|
        path = ["workflows", wf_name, "jobs", i]
        deps = []
        Array(cfg["requires"]).each do |req|
          targets = sources[req.to_s]
          if targets.nil? || targets.empty?
            errors.add(path + [inst, "requires"],
                       "job #{inst.inspect} requires unknown job or matrix alias #{req.inspect}")
            next
          end
          targets.each do |target|
            if active[target]
              deps << target
            else
              warnings << "job #{inst.inspect} requires #{target.inspect}, which was filtered out " \
                          "by branch filters; treating the dependency as satisfied"
            end
          end
        end
        edges[inst] = deps.uniq
      end
      return nil if errors.any?

      # 4. Cycle detection + topological order over active instances only.
      active_names = instances.map(&:first).select { |n| active[n] }
      pruned = active_names.to_h { |n| [n, edges[n].select { |d| active[d] }] }
      if (cycle = DAG.find_cycle(active_names, pruned))
        errors.add(["workflows", wf_name], "dependency cycle detected: #{cycle.join(' -> ')}")
        return nil
      end
      order = DAG.toposort(active_names, pruned)

      # 5. Emit IR jobs in topological order.
      lookup = instances.to_h { |inst, base, cfg, combo| [inst, [base, cfg, combo]] }
      jobs_ir = order.map do |inst|
        base, _cfg, combo = lookup[inst]
        build_job_ir(inst, base, combo, jobs_def, errors, ctx, on_missing)
      end
      return nil if errors.any?

      IR.workflow(wf_name, jobs_ir)
    end

    def build_job_ir(instance_name, base_name, matrix_values, jobs_def, errors, ctx, on_missing)
      job_def = deep_dup(jobs_def[base_name])
      job_ctx = ctx.merge("matrix" => matrix_values)
      job_def = Interpolator.interpolate(job_def, job_ctx, errors, ["jobs", base_name], on_missing: on_missing)
      # Anything still unresolved here is a real problem — except pipeline
      # values, which were deliberately left with a warning above.
      leftover = Interpolator.unresolved_refs(job_def).reject { |r| Interpolator.pipeline_ref?(r) }
      unless leftover.empty?
        errors.add(["jobs", base_name],
                   "unresolved interpolation #{leftover.map { |r| "<< #{r} >>" }.join(', ')}; " \
                   "matrix references are only allowed inside matrix jobs")
        return nil
      end
      job_def["steps"] = evaluate_conditionals(job_def["steps"] || [], errors, ["jobs", base_name, "steps"])
      IR.job(instance_name, job_def)
    end

    def matrix_combinations(parameters)
      keys = parameters.keys.map(&:to_s)
      values = keys.map { |k| Array(parameters[k]) }
      values.first.product(*values.drop(1)).map do |combo|
        keys.zip(Array(combo)).to_h
      end
    end

    # --- branch filters ------------------------------------------------------------

    def branch_matches?(filters, branch)
      branches = (filters || {})["branches"] || {}
      only = branches["only"]
      ignore = branches["ignore"]
      return false if only && !matches_any?(only, branch)
      return false if ignore && matches_any?(ignore, branch)

      true
    end

    def matches_any?(patterns, branch)
      Array(patterns).any? do |pattern|
        if pattern.start_with?("/") && pattern.end_with?("/") && pattern.length > 1
          begin
            Regexp.new(pattern[1..-2]).match?(branch.to_s)
          rescue RegexpError
            false
          end
        else
          pattern == branch
        end
      end
    end

    # --- when / unless conditional steps ----------------------------------------------

    # Evaluates compile-time conditional steps. Conditions were interpolated
    # already, so they are booleans (or "true"/"false" strings).
    def evaluate_conditionals(steps, errors, path)
      result = []
      steps.each_with_index do |step, i|
        unless step.is_a?(Hash) && step.size == 1
          result << step
          next
        end
        type, cfg = step.first
        unless %w[when unless].include?(type.to_s)
          result << step
          next
        end
        cond = truthy?(cfg["condition"], errors, path + [i, type, "condition"])
        include_steps = type.to_s == "when" ? cond : !cond
        next unless include_steps

        result.concat(evaluate_conditionals(cfg["steps"] || [], errors, path + [i, type, "steps"]))
      end
      result
    end

    def truthy?(value, errors, path)
      case value
      when true, "true" then true
      when false, "false" then false
      else
        errors.add(path, "condition must resolve to true/false (got #{value.inspect}); " \
                         "use a boolean parameter like \"<< parameters.run_lint >>\"")
        false
      end
    end

    # --- misc --------------------------------------------------------------------------

    def deep_dup(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
      when Array then obj.map { |v| deep_dup(v) }
      else obj
      end
    end
  end
end
