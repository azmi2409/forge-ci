# frozen_string_literal: true

module ForgeCI
  # Normalizes the validated, expanded, interpolated config into the
  # intermediate representation (IR): plain Ruby hashes with symbol keys,
  # JSON-serializable, ready for a scheduler/runner to consume.
  #
  # Only called when validation produced no errors, so normalization can
  # assume well-formed input and focus on shaping.
  module IR
    module_function

    def document(version, workflows, warnings)
      {
        version: version.to_s,
        workflows: workflows,
        meta: { warnings: warnings }
      }
    end

    def workflow(name, jobs)
      { name: name, jobs: jobs }
    end

    def job(name, job_def, requires = [])
      {
        name: name,
        # Pruned `requires` edges for this job instance (topological scheduler
        # seam for the control plane): names of jobs in the same workflow that
        # must complete successfully before this job may run.
        requires: Array(requires).map(&:to_s),
        executor: executor(job_def),
        working_directory: job_def["working_directory"],
        steps: Array(job_def["steps"]).map { |s| step(s) }
      }
    end

    def executor(job_def)
      images = Array(job_def["docker"])
      primary = images.first || {}
      {
        type: "docker",
        image: primary["image"],
        name: primary["name"],
        entrypoint: primary["entrypoint"],
        command: primary["command"],
        environment: merged_environment(primary["environment"], job_def["environment"]),
        secondary_images: images.drop(1).map do |img|
          {
            image: img["image"],
            name: img["name"],
            entrypoint: img["entrypoint"],
            command: img["command"],
            environment: img["environment"] || {}
          }
        end,
        resource_class: job_def["resource_class"]
      }
    end

    def merged_environment(image_env, job_env)
      merged = {}
      merged.merge!(image_env) if image_env.is_a?(Hash)
      merged.merge!(job_env) if job_env.is_a?(Hash)
      merged
    end

    def step(step)
      type, cfg = step.first
      cfg = {} if cfg.nil?
      type = type.to_s

      base =
        case type
        when "when", "unless"
          # Conditional wrappers are evaluated at compile time; by the time
          # the IR is built only the surviving steps remain. Reaching here
          # means a bug in the compiler.
          raise Error, "internal error: unevaluated #{type}: step reached IR normalization"
        when "checkout"
          { type: "checkout", path: cfg["path"] }
        when "run"
          {
            type: "run",
            name: cfg["name"] || cfg["command"],
            command: cfg["command"],
            shell: cfg["shell"],
            background: cfg.fetch("background", false),
            when: cfg.fetch("when", "on_success")
          }
        when "save_cache"
          { type: "save_cache", keys: cache_keys(cfg), paths: cfg["paths"] || [] }
        when "restore_cache"
          { type: "restore_cache", keys: cache_keys(cfg) }
        when "persist_to_workspace"
          { type: "persist_to_workspace", root: cfg["root"], paths: cfg["paths"] || [] }
        when "attach_workspace"
          { type: "attach_workspace", at: cfg["at"] }
        when "store_artifacts"
          { type: "store_artifacts", path: cfg["path"], destination: cfg["destination"] }
        when "store_test_results"
          { type: "store_test_results", path: cfg["path"] }
        when "add_ssh_keys"
          { type: "add_ssh_keys", fingerprints: cfg["fingerprints"] || [] }
        else
          raise Error, "internal error: unknown step type #{type.inspect} reached IR normalization"
        end
      base
    end

    def cache_keys(cfg)
      return cfg["keys"] if cfg["keys"].is_a?(Array)

      [cfg["key"]].compact
    end
  end
end
