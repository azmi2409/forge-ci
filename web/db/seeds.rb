# frozen_string_literal: true

# Demo seed: a project, a runner token, a context, and a pipeline compiled
# from a sample config with the REAL forge-ci gem — so the UI shows something
# on first boot.
#
# The raw runner token is printed to stdout (it is shown ONCE and never stored).
#
# Development only: `db:prepare` runs seeds when it creates a database, and a
# real install must not start with a demo project, runner token and pipeline.
# Set FORGE_CI_SEED_DEMO=1 to seed anyway.
if Rails.env.production? && ENV["FORGE_CI_SEED_DEMO"] != "1"
  puts "Skipping demo seed data in production (set FORGE_CI_SEED_DEMO=1 to load it)."
  return
end

project = Project.find_or_create_by!(name: "demo") do |p|
  p.repo_url = "https://github.com/example/demo"
  p.default_branch = "main"
  p.max_concurrency = 4
end

token_record = RunnerToken.find_by(name: "demo-runner")
if token_record
  puts "Runner token 'demo-runner' already exists (raw token not recoverable — delete and re-seed to rotate)."
else
  _record, raw = RunnerToken.generate!(name: "demo-runner", resource_class: "medium")
  puts "Runner token (raw, shown once — save it now): #{raw}"
end

context = project.contexts.find_or_create_by!(name: "demo-deploy")
context.update!(payload: { "DEPLOY_KEY" => "demo-secret-value", "REGISTRY" => "registry.example.com" })

yaml = <<~YAML
  version: 2.1
  jobs:
    build:
      docker:
        - image: cimg/ruby:3.2
      resource_class: medium
      environment:
        RAILS_ENV: test
      steps:
        - checkout
        - run:
            name: Install dependencies
            command: bundle install
    test:
      docker:
        - image: cimg/ruby:3.2
      resource_class: medium
      steps:
        - checkout
        - run:
            name: Run tests
            command: bin/rails test
    deploy:
      docker:
        - image: cimg/ruby:3.2
      resource_class: medium
      environment:
        DEPLOY_ENV: staging
      steps:
        - run:
            name: Deploy
            command: ./deploy.sh $DEPLOY_ENV
  workflows:
    build-test-deploy:
      jobs:
        - build
        - test:
            requires: [build]
        - deploy:
            requires: [test]
YAML

ir, errors = ForgeCI::Compiler.compile(yaml)
raise "seed config failed to compile: #{errors.inspect}" if errors.any?

pipeline = PipelineIntake.call!(
  project: project,
  sha: "abc123def4567890",
  branch: "main",
  ir: ir,
  context_names: ["demo-deploy"]
)

puts "Seeded pipeline #{pipeline.id}: " \
     "#{pipeline.workflow_runs.count} workflow(s), " \
     "#{pipeline.job_runs.count} job(s) " \
     "(#{pipeline.job_runs.queued.count} queued, #{pipeline.job_runs.pending.count} pending)"
