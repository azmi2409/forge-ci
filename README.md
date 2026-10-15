# forge-ci

An open-source, CircleCI-compatible CI toolkit.

`forge-ci` compiles CircleCI v2.1-style pipeline YAML (`.circleci/config.yml`) into a
normalized, JSON-serializable **intermediate representation (IR)** that a scheduler
and runner can execute. It is component 1 of the ForgeCI project.

Pure Ruby, **stdlib only** (psych, json in tests) — no network, no processes, no
dependencies. Tested on **Ruby 3.2.3** (requires >= 3.0).

## Repository layout

- `/` — the `forge-ci` gem: the **config compiler** (MVP component 1)
- `web/` — the **Rails control plane** (MVP components 2 + 4): Postgres models,
  pipeline intake from compiler IR, token-authenticated runner claim API, minimal
  web UI. See `web/README.md`.
- `runner/` — the **Docker runner** (MVP component 5): zero-dependency Ruby
  daemon that polls for jobs and executes them in Docker containers. See
  `runner/README.md`.

## Install

```ruby
# Gemfile
gem "forge-ci"
```

Or build locally:

```sh
gem build forge-ci.gemspec
gem install ./forge-ci-0.1.0.gem
```

## Usage

```ruby
require "forge_ci"

yaml = File.read(".circleci/config.yml")

ir, errors = ForgeCI::Compiler.compile(
  yaml,
  pipeline_params: {
    "branch"     => "main",   # resolves << pipeline.git.branch >> and branch filters
    "number"     => 42,       # resolves << pipeline.number >>
    "parameters" => { "deploy_env" => "production" } # overrides for top-level `parameters:`
  }
)

if errors.empty?
  puts JSON.pretty_generate(ir)
else
  puts errors # actionable messages with YAML line numbers
end

# Just validation, no IR:
errors = ForgeCI::Compiler.validate(yaml)
```

`compile` returns `[ir, errors]`. `errors` is empty on success; `ir` is `nil`
when errors are present. `ForgeCI::Error` is raised **only** when the YAML text
cannot be parsed at all — everything else (unknown keys, bad references,
dependency cycles) comes back as error strings like:

```
line 63: jobs.build.steps.1: unknown step type "frobnicate"; supported steps: checkout, run, ...
```

### IR shape

```ruby
{
  version: "2.1",
  workflows: [
    {
      name: "build-test-deploy",
      jobs: [
        {
          name: "build",
          executor: {
            type: "docker",
            image: "cimg/node:20",
            name: nil, entrypoint: nil, command: nil,
            environment: { "NODE_ENV" => "test" },
            secondary_images: [{ image: "redis:7", name: "redis", entrypoint: nil, command: nil, environment: {} }],
            resource_class: "medium"
          },
          working_directory: "~/project",
          steps: [
            { type: "checkout", path: nil },
            { type: "run", name: "Build", command: "npm run build",
              shell: nil, background: false, when: "on_success" },
            { type: "save_cache", keys: ["node-deps-v1-abc"], paths: ["node_modules"] },
            # ...
          ]
        }
      ]
    }
  ],
  meta: { warnings: ["no branch supplied via pipeline_params; ..."] }
}
```

Jobs inside each workflow are emitted in **topological order** of their
`requires` edges.

## Supported subset vs CircleCI

| CircleCI v2.1 feature | forge-ci v1 |
|---|---|
| `version: 2.1` | ✅ |
| `parameters:` (string/boolean/integer/enum, defaults, overrides) | ✅ |
| `commands:` reusable steps with parameters | ✅ (inlined at compile time) |
| `executors:` reusable executors with parameters | ✅ (inlined; job-level keys win) |
| `jobs:` with `docker:` executor (primary + service images) | ✅ |
| `working_directory`, `environment`, `resource_class` | ✅ |
| Steps: `checkout`, `run`, `save_cache`, `restore_cache`, `persist_to_workspace`, `attach_workspace`, `store_artifacts`, `store_test_results`, `add_ssh_keys` | ✅ |
| `run:` shorthand (`- run: echo hi`), `when: on_success/on_fail/always` | ✅ |
| `when:`/`unless:` conditional steps | ✅ (evaluated at compile time) |
| `<< parameters.x >>`, `<< pipeline.git.branch >>`, `<< pipeline.number >>` | ✅ |
| Workflows: `requires` DAG, cycle detection, topological order | ✅ |
| `filters: branches: only/ignore` (plain names and `/regex/`) | ✅ |
| `matrix:` (desugared to `job-0`, `job-1`, …; alias usable in `requires`) | ✅ |
| `orbs:` | ❌ rejected with a clear error (no registry in v1) |
| `machine:` / `macos:` executors | ❌ rejected with a clear error (Docker only) |
| `type: approval` jobs | ❌ rejected with a clear error |
| Dynamic config (`setup:` workflows), `pipeline.continue` | ❌ not yet supported |
| Docker layer caching, `parallelism` / test splitting | ❌ not yet supported |
| `filters: tags:` | ⚠️ parsed, ignored with a warning |
| Missing `workflows:` | ⚠️ implicit `default` workflow with a warning |
| `<< pipeline.git.branch >>` / `<< pipeline.number >>` without values | ⚠️ left unresolved with a warning |

Cache `keys:` templates (e.g. `{{ checksum "package.json" }}`) are passed
through untouched — checksum expansion is a runner concern.

## Design notes

- **Compile is a pure function.** YAML text in, IR out. No I/O, no network,
  no Docker — the whole thing is unit-testable offline.
- **Validation is compilation.** Like CircleCI's own `configs/compile`
  endpoint, there is no separate "validate then run" — one pass collects every
  structural problem with file locations.
- **Expansion before interpolation.** Reusable commands/executors are inlined
  first (with their own parameter scope), then global `<< >>` references
  resolve, then `when`/`unless` conditionals evaluate, then the workflow DAG
  is built. Matrix `<< matrix.x >>` references resolve per desugared job.
- **Errors, not exceptions.** The only raise is `ForgeCI::Error` on
  unparseable YAML. Error strings carry Psych line numbers where the AST can
  locate the key.
- **Warnings vs errors.** Anything that changes what runs (unknown step,
  cycle, bad reference) is an error. Anything informational (no branch
  supplied, tags filters ignored, implicit workflow) lands in
  `ir[:meta][:warnings]`.

## Roadmap

1. ✅ **Config compiler** (this gem)
2. **Control plane** — Rails + Postgres: projects, pipelines, workflow/job
   state machines, REST API, GitHub App webhooks, polling job-claim API
3. **Docker runner** — polling daemon: claim → `docker run` → step execution
   → log streaming → artifact upload → report
4. **Log streaming, cache/artifacts on S3-compatible storage, contexts/secrets**

## Development

```sh
rake test   # minitest suite, fixtures in test/fixtures/
```

## License

MIT — see [MIT-LICENSE](MIT-LICENSE).
