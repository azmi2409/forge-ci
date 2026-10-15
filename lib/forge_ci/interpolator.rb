# frozen_string_literal: true

module ForgeCI
  # Pure string-substitution pass for CircleCI-style template references:
  #
  #   << parameters.deploy_env >>      pipeline parameter (top-level `parameters:`)
  #   << pipeline.git.branch >>       supplied via pipeline_params["branch"]
  #   << pipeline.number >>           supplied via pipeline_params["number"]
  #   << matrix.node_version >>       only while desugaring matrix jobs
  #
  # Anything else is an error (collected, not raised). When the whole string
  # is a single reference, the native Ruby value is preserved (so booleans
  # and integers survive); embedded references are stringified.
  #
  # Two scoping knobs exist because references resolve in stages:
  # - only: allowlist of full reference strings (e.g. a command's own
  #   parameter names); anything else is left untouched for a later pass.
  # - skip_prefixes: denylist of reference prefixes left untouched
  #   (e.g. "matrix." during the global pass; matrix jobs resolve them later).
  module Interpolator
    REF = /<<\s*([^<>]+?)\s*>>/
    FULL_REF = /\A#{REF.source}\z/

    module_function

    # context is a Hash with string keys: "parameters", "pipeline", "matrix".
    def interpolate(obj, context, errors, path, only: nil, skip_prefixes: [], on_missing: nil)
      case obj
      when String
        interpolate_string(obj, context, errors, path, only: only, skip_prefixes: skip_prefixes, on_missing: on_missing)
      when Array
        obj.map.with_index { |item, i| interpolate(item, context, errors, path + [i], only: only, skip_prefixes: skip_prefixes, on_missing: on_missing) }
      when Hash
        obj.each_with_object({}) do |(k, v), out|
          new_key = k.is_a?(String) ? interpolate_string(k, context, errors, path, only: only, skip_prefixes: skip_prefixes, on_missing: on_missing) : k
          out[new_key] = interpolate(v, context, errors, path + [k], only: only, skip_prefixes: skip_prefixes, on_missing: on_missing)
        end
      else
        obj
      end
    end

    def interpolate_string(str, context, errors, path, only: nil, skip_prefixes: [], on_missing: nil)
      return str unless str.match?(REF)

      if (m = str.match(FULL_REF))
        ref = m[1].strip
        return str if passthrough?(ref, only, skip_prefixes)

        found, value = resolve(ref, context)
        return value if found
        return on_missing.call(ref, path) if on_missing && pipeline_ref?(ref)

        errors.add(path, "unknown interpolation reference \"<< #{ref} >>\"; " \
                         "expected parameters.<name>, pipeline.git.branch, pipeline.number, or matrix.<name>")
        return str
      end

      str.gsub(REF) do
        ref = Regexp.last_match(1).strip
        if passthrough?(ref, only, skip_prefixes)
          "<< #{ref} >>"
        else
          found, value = resolve(ref, context)
          if found
            value.to_s
          elsif on_missing && pipeline_ref?(ref)
            on_missing.call(ref, path)
          else
            errors.add(path, "unknown interpolation reference \"<< #{ref} >>\"; " \
                             "expected parameters.<name>, pipeline.git.branch, pipeline.number, or matrix.<name>")
            "<< #{ref} >>"
          end
        end
      end
    end

    # Returns [found, value]. Unknown references return [false, nil].
    def resolve(ref, context)
      case ref
      when /\Aparameters\.(.+)\z/
        params = context["parameters"] || {}
        name = Regexp.last_match(1)
        return [true, params[name]] if params.key?(name)

        [false, nil]
      when "pipeline.git.branch"
        pipeline = context["pipeline"] || {}
        return [true, pipeline["branch"]] unless pipeline["branch"].nil?

        [false, nil]
      when "pipeline.number"
        pipeline = context["pipeline"] || {}
        return [true, pipeline["number"]] unless pipeline["number"].nil?

        [false, nil]
      when /\Amatrix\.(.+)\z/
        matrix = context["matrix"] || {}
        name = Regexp.last_match(1)
        return [true, matrix[name]] if matrix.key?(name)

        [false, nil]
      else
        [false, nil]
      end
    end

    # All "<< ... >>" references still present in the object (after passes
    # that intentionally left some unresolved).
    def unresolved_refs(obj)
      refs = []
      walk = lambda do |o|
        case o
        when String then o.scan(REF) { refs << Regexp.last_match(1).strip }
        when Array then o.each { |item| walk.call(item) }
        when Hash then o.each { |k, v| walk.call(k); walk.call(v) }
        end
      end
      walk.call(obj)
      refs.uniq
    end

    def passthrough?(ref, only, skip_prefixes)
      return true if skip_prefixes.any? { |prefix| ref.start_with?(prefix) }
      return true if only && !only.include?(ref)

      false
    end

    # << pipeline.git.branch >> / << pipeline.number >> are valid references
    # even when no value was supplied; the compiler leaves them unresolved
    # with a warning instead of erroring.
    def pipeline_ref?(ref)
      ref == "pipeline.git.branch" || ref == "pipeline.number"
    end
  end
end
