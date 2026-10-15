# frozen_string_literal: true

# Turns a compiler IR (as produced by ForgeCI::Compiler.compile) into a
# Pipeline + WorkflowRuns + JobRuns + StepRuns.
#
# This is the seam the GitHub App (component 3) will call: it compiles
# .circleci/config.yml with the forge-ci gem and POSTs the resulting IR here.
#
# The IR arrives as JSON (string keys after the round-trip); symbol-keyed IR
# straight from the gem is accepted too and normalized.
class PipelineIntake
  class IntakeError < StandardError
    attr_reader :http_status, :details

    def initialize(http_status, message, details = [])
      @http_status = http_status
      @details = details
      super(message)
    end
  end

  def self.call!(project:, sha:, branch:, ir:, context_names: [])
    new(project: project, sha: sha, branch: branch, ir: ir, context_names: context_names).call!
  end

  def initialize(project:, sha:, branch:, ir:, context_names: [])
    @project = project
    @sha = sha
    @branch = branch
    # Normalize to a plain string-keyed hash. The IR arrives over HTTP as
    # ActionController::Parameters; direct Ruby callers (seeds, console) may
    # pass the gem's symbol-keyed IR or a plain string-keyed hash.
    plain = ir.respond_to?(:to_unsafe_h) ? ir.to_unsafe_h : (ir || {})
    @ir = ::JSON.parse(::JSON.dump(plain))
    @context_names = Array(context_names).map(&:to_s).uniq
  end

  def call!
    validate_ir!
    contexts = resolve_contexts!
    context_env = merge_context_env(contexts)

    Pipeline.transaction do
      pipeline = @project.pipelines.create!(sha: @sha, branch: @branch, status: "running")

      @ir["workflows"].each do |wf|
        wf_name = wf["name"].to_s
        workflow_run = pipeline.workflow_runs.create!(name: wf_name, status: "running")

        wf["jobs"].each do |job|
          job_name = job["name"].to_s
          executor = job["executor"] || {}
          requires = Array(job["requires"]).map(&:to_s)

          job_run = workflow_run.job_runs.create!(
            name: job_name,
            executor: executor,
            steps: Array(job["steps"]),
            working_directory: job["working_directory"],
            requires: requires,
            resource_class: executor["resource_class"],
            context_environment: context_env,
            concurrency_key: [@project.id, wf_name, job_name].join("/"),
            status: requires.empty? ? "queued" : "pending"
          )

          Array(job["steps"]).each do |step|
            step_name = (step["name"] || step["type"]).to_s
            job_run.step_runs.create!(name: step_name.presence || "step", status: "pending")
          end
        end
      end

      pipeline
    end
  end

  private

  def validate_ir!
    errors = []

    workflows = @ir["workflows"]
    if !workflows.is_a?(Array) || workflows.empty?
      errors << "ir.workflows must be a non-empty array"
    else
      workflows.each_with_index do |wf, i|
        path = "ir.workflows[#{i}]"
        errors << "#{path}.name is required" if wf["name"].blank?

        jobs = wf["jobs"]
        if !jobs.is_a?(Array) || jobs.empty?
          errors << "#{path}.jobs must be a non-empty array"
          next
        end

        jobs.each_with_index do |job, j|
          jpath = "#{path}.jobs[#{j}]"
          errors << "#{jpath}.name is required" if job["name"].blank?
          errors << "#{jpath}.executor is required" unless job["executor"].is_a?(Hash)
          errors << "#{jpath}.steps must be an array" unless job["steps"].is_a?(Array)
        end
      end
    end

    raise IntakeError.new(422, "invalid IR", errors) if errors.any?
  end

  def resolve_contexts!
    return [] if @context_names.empty?

    found = @project.contexts.where(name: @context_names).to_a
    missing = @context_names - found.map(&:name)
    if missing.any?
      raise IntakeError.new(404, "unknown context(s) for project #{@project.id}: #{missing.join(', ')}")
    end

    # Preserve the requested order so later contexts override earlier ones.
    found.sort_by { |c| @context_names.index(c.name) }
  end

  def merge_context_env(contexts)
    env = {}
    contexts.each { |c| env.merge!(c.payload) }
    env
  end
end
