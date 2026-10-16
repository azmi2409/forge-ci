# frozen_string_literal: true

require_relative "test_helper"

class CompilerTest < Minitest::Test
  def compile_full(branch: "main", params: {})
    ForgeCI::Compiler.compile(
      fixture("full.yml"),
      pipeline_params: { "branch" => branch, "number" => 42 }.merge(params)
    )
  end

  def first_workflow(ir)
    ir[:workflows].first
  end

  def job_by_name(ir, name)
    first_workflow(ir)[:jobs].find { |j| j[:name] == name }
  end

  # --- happy path ---------------------------------------------------------

  def test_full_workflow_compiles_cleanly
    ir, errors = compile_full
    assert_empty errors, "expected no errors, got: #{errors.inspect}"
    assert_equal "2.1", ir[:version]
    assert_equal ["build-test-deploy"], ir[:workflows].map { |w| w[:name] }
  end

  def test_topological_job_order_follows_requires
    ir, = compile_full
    names = first_workflow(ir)[:jobs].map { |j| j[:name] }
    assert_equal %w[build test deploy], names
  end

  def test_executor_reference_expands_with_parameters
    ir, = compile_full
    build = job_by_name(ir, "build")
    assert_equal "docker", build[:executor][:type]
    assert_equal "cimg/node:20", build[:executor][:image]
    assert_equal "medium", build[:executor][:resource_class]
    assert_equal "~/project", build[:working_directory]
    assert_equal({ "NODE_ENV" => "test" }, build[:executor][:environment])
  end

  def test_secondary_service_images_normalized
    ir, = compile_full
    test = job_by_name(ir, "test")
    assert_equal "cimg/node:20", test[:executor][:image]
    assert_equal(
      [{ image: "redis:7", name: "redis", entrypoint: nil, command: nil, environment: {} }],
      test[:executor][:secondary_images]
    )
  end

  def test_command_expansion_inlines_steps_with_parameter_values
    ir, = compile_full
    build = job_by_name(ir, "build")
    types = build[:steps].map { |s| s[:type] }
    assert_equal %w[checkout run run save_cache persist_to_workspace store_test_results store_artifacts],
                 types
    install = build[:steps][1]
    assert_equal "Install dependencies", install[:name]
    assert_match(/npm ci/, install[:command])
  end

  def test_run_shorthand_normalizes_to_named_step
    ir, = compile_full
    test = job_by_name(ir, "test")
    npm_test = test[:steps].find { |s| s[:command] == "npm test" }
    assert_equal "npm test", npm_test[:name]
    assert_equal "on_success", npm_test[:when]
    assert_equal false, npm_test[:background]
  end

  def test_cache_workspace_artifact_steps_normalized
    ir, = compile_full
    build = job_by_name(ir, "build")
    save = build[:steps].find { |s| s[:type] == "save_cache" }
    assert_equal ["node-deps-v1-{{ checksum \"package.json\" }}", "node-deps-v1-"], save[:keys]
    assert_equal ["node_modules"], save[:paths]

    persist = build[:steps].find { |s| s[:type] == "persist_to_workspace" }
    assert_equal ".", persist[:root]
    assert_equal ["dist"], persist[:paths]

    artifact = build[:steps].find { |s| s[:type] == "store_artifacts" }
    assert_equal "dist/bundle.js", artifact[:path]
    assert_equal "bundle", artifact[:destination]
  end

  def test_when_conditional_false_drops_steps
    ir, = compile_full
    test = job_by_name(ir, "test")
    refute test[:steps].any? { |s| s[:name] == "Extra E2E" },
           "steps under a false `when:` condition must be removed"
  end

  def test_when_conditional_true_keeps_steps
    ir, errors = compile_full(params: { "parameters" => { "run_e2e" => true } })
    assert_empty errors
    test = job_by_name(ir, "test")
    assert test[:steps].any? { |s| s[:name] == "Extra E2E" },
           "steps under a true `when:` condition must be kept"
  end

  # --- branch filters ------------------------------------------------------

  def test_branch_filter_only_matches_main
    ir, errors = compile_full(branch: "main")
    assert_empty errors
    names = first_workflow(ir)[:jobs].map { |j| j[:name] }
    assert_includes names, "deploy"
  end

  def test_branch_filter_excludes_feature_branch
    ir, errors = compile_full(branch: "feature/login")
    assert_empty errors
    names = first_workflow(ir)[:jobs].map { |j| j[:name] }
    assert_equal %w[build test], names
  end

  def test_branch_filter_supports_regex_patterns
    ir, errors = compile_full(branch: "release/v2")
    assert_empty errors
    names = first_workflow(ir)[:jobs].map { |j| j[:name] }
    assert_includes names, "deploy"
  end

  def test_missing_branch_warns_but_keeps_jobs
    ir, errors = ForgeCI::Compiler.compile(fixture("full.yml"), pipeline_params: { "number" => 1 })
    assert_empty errors
    assert_match(/no branch supplied/, ir[:meta][:warnings].join(" "))
    names = first_workflow(ir)[:jobs].map { |j| j[:name] }
    assert_includes names, "deploy"
  end

  # --- interpolation --------------------------------------------------------

  def test_pipeline_values_interpolate
    ir, errors = ForgeCI::Compiler.compile(
      fixture("interpolation.yml"),
      pipeline_params: { "branch" => "main", "number" => 7 }
    )
    assert_empty errors
    job = first_workflow(ir)[:jobs].first
    assert_equal "hello", job[:executor][:environment]["GREETING"]
    assert_equal 'echo "hello from branch main (build #7)"', job[:steps].first[:command]
  end

  def test_parameter_override
    ir, errors = compile_full(params: { "parameters" => { "deploy_env" => "production" } })
    assert_empty errors
    deploy = job_by_name(ir, "deploy")
    step = deploy[:steps].find { |s| s[:type] == "run" && s[:name] == "Deploy to production" }
    refute_nil step, "parameter override should flow into step name and command"
    assert_match(%r{\./deploy\.sh production 42}, step[:command])
  end

  def test_deploy_step_uses_parameter_defaults
    ir, = compile_full
    deploy = job_by_name(ir, "deploy")
    step = deploy[:steps].find { |s| s[:name] == "Deploy to staging" }
    refute_nil step
    ssh = deploy[:steps].find { |s| s[:type] == "add_ssh_keys" }
    assert_equal ["aa:bb:cc:dd"], ssh[:fingerprints]
  end

  # --- matrix ---------------------------------------------------------------

  def test_matrix_desugars_into_numbered_jobs
    ir, errors = ForgeCI::Compiler.compile(fixture("matrix.yml"))
    assert_empty errors
    jobs = first_workflow(ir)[:jobs]
    assert_equal %w[test-0 test-1 report], jobs.map { |j| j[:name] }
  end

  def test_matrix_values_interpolate_per_job
    ir, = ForgeCI::Compiler.compile(fixture("matrix.yml"))
    jobs = first_workflow(ir)[:jobs]
    assert_equal "cimg/ruby:3.1", jobs[0][:executor][:image]
    assert_equal "cimg/ruby:3.2", jobs[1][:executor][:image]
    assert_match(/RUBY=3\.1/, jobs[0][:steps].first[:command])
    assert_match(/Test on Ruby 3\.2/, jobs[1][:steps].first[:name])
  end

  def test_matrix_alias_fans_in_downstream_requires
    ir, = ForgeCI::Compiler.compile(fixture("matrix.yml"))
    jobs = first_workflow(ir)[:jobs]
    assert_equal "report", jobs.last[:name], "report must run after all matrix jobs"
  end

  def test_requires_edges_survive_compilation_for_control_plane
    ir, errors = compile_full
    assert_empty errors, "expected no errors, got: #{errors.inspect}"
    by_name = first_workflow(ir)[:jobs].to_h { |j| [j[:name], j] }
    assert_equal [], by_name["build"][:requires], "root job has no dependencies"
    assert_equal ["build"], by_name["test"][:requires], "test depends on build"
    assert_equal ["test"], by_name["deploy"][:requires], "deploy depends on test"
  end

  # --- errors ----------------------------------------------------------------

  def test_dependency_cycle_is_an_error
    ir, errors = ForgeCI::Compiler.compile(fixture("invalid_cycle.yml"))
    assert_nil ir
    assert_match(/dependency cycle detected: a -> b -> a/, errors.join("\n"))
  end

  def test_unknown_step_type_is_an_error_with_line_number
    _ir, errors = ForgeCI::Compiler.compile(fixture("invalid_unknown_step.yml"))
    assert_match(/unknown step type "frobnicate"/, errors.join("\n"))
    assert_match(/line \d+/, errors.join("\n"))
  end

  def test_unknown_interpolation_references_are_errors
    _ir, errors = ForgeCI::Compiler.compile(fixture("invalid_bad_interpolation.yml"))
    joined = errors.join("\n")
    assert_match(/unknown interpolation reference "<< parameters\.typo >>"/, joined)
    assert_match(/unknown interpolation reference "<< pipeline\.git\.sha >>"/, joined)
  end

  def test_orbs_are_rejected_with_a_clear_message
    _ir, errors = ForgeCI::Compiler.compile(fixture("invalid_orbs.yml"))
    assert_match(/orb registry is not supported in forge-ci v1/, errors.join("\n"))
  end

  def test_machine_executor_is_rejected
    _ir, errors = ForgeCI::Compiler.compile(fixture("invalid_unknown_executor.yml"))
    assert_match(/only Docker executors are supported in v1/, errors.join("\n"))
  end

  def test_requires_unknown_job_is_an_error
    _ir, errors = ForgeCI::Compiler.compile(fixture("invalid_requires_unknown.yml"))
    assert_match(/requires unknown job or matrix alias "nonexistent"/, errors.join("\n"))
  end

  def test_unparseable_yaml_raises_forge_ci_error
    assert_raises(ForgeCI::Error) do
      ForgeCI::Compiler.compile("jobs: [unclosed\n  bad: : :")
    end
  end

  # --- validate ---------------------------------------------------------------

  def test_validate_returns_error_strings
    errors = ForgeCI::Compiler.validate(fixture("invalid_cycle.yml"))
    assert_kind_of Array, errors
    refute_empty errors
    assert errors.all? { |e| e.is_a?(String) }
  end

  def test_validate_clean_config_returns_empty
    assert_empty ForgeCI::Compiler.validate(fixture("matrix.yml"))
  end

  def test_validate_raises_on_unparseable_yaml
    assert_raises(ForgeCI::Error) { ForgeCI::Compiler.validate(":\n: bad") }
  end

  # --- IR shape -----------------------------------------------------------------

  def test_ir_is_json_serializable
    ir, errors = compile_full
    assert_empty errors
    parsed = JSON.parse(JSON.generate(ir))
    assert_equal "2.1", parsed["version"]
    assert_equal "build", parsed["workflows"].first["jobs"].first["name"]
    assert_kind_of Array, parsed["meta"]["warnings"]
  end

  def test_ir_step_keys_are_stable
    ir, = compile_full
    build = job_by_name(ir, "build")
    run = build[:steps].find { |s| s[:type] == "run" && s[:name] == "Build" }
    assert_equal %i[type name command shell background when].sort, run.keys.sort
  end

  def test_run_step_carries_environment_and_no_output_timeout
    yaml = <<~YAML
      version: 2.1
      jobs:
        a:
          docker: [{image: "ruby:3.3"}]
          steps:
            - run:
                command: ./slow.sh
                environment: {FOO: bar}
                no_output_timeout: 30m
      workflows:
        w:
          jobs: [a]
    YAML
    ir, errors = ForgeCI::Compiler.compile(yaml)
    assert_empty errors
    run = ir[:workflows].first[:jobs].first[:steps].first
    assert_equal({ "FOO" => "bar" }, run[:environment])
    assert_equal "30m", run[:no_output_timeout]
  end

  def test_bad_no_output_timeout_is_a_validation_error
    yaml = <<~YAML
      version: 2.1
      jobs:
        a:
          docker: [{image: "ruby:3.3"}]
          steps:
            - run: {command: x, no_output_timeout: soon}
      workflows:
        w:
          jobs: [a]
    YAML
    _ir, errors = ForgeCI::Compiler.compile(yaml)
    assert(errors.any? { |e| e.to_s.include?("no_output_timeout") })
  end
end
