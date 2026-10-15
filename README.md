# forge-ci

[![CI](https://github.com/azmi2409/forge-ci/actions/workflows/ci.yml/badge.svg)](https://github.com/azmi2409/forge-ci/actions/workflows/ci.yml)

An open-source, **CircleCI-compatible CI/CD system** — pure Ruby, MIT licensed.

**Status: MVP complete.** All 8 planned components are built, tested (259 runs,
1023 assertions, green), and running from this repo.

Push code to GitHub → webhook → config compiled → jobs claimed by polling
runners → executed in Docker → results and commit statuses posted back. No
inbound ports on runners, no proprietary control plane.

## Quickstart

**1. Validate a config anywhere (Ruby ≥ 3.0 only, no Docker):**

```sh
gem build forge-ci.gemspec && gem install ./forge-ci-0.1.0.gem
forge-ci validate .circleci/config.yml
forge-ci compile .circleci/config.yml --branch main
```

**2. Run the full system locally** (needs Docker for the runner):

```sh
# Control plane (SQLite fallback for dev; Postgres for production)
cd web
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails db:prepare db:seed
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails server
# → http://localhost:3000 (admin / password in dev)

# Runner (separate shell; needs Docker Engine)
cd ../runner
CONTROL_PLANE_URL="http://localhost:3000" \
RUNNER_TOKEN="<raw token printed by db:seed>" \
  bin/forge-ci-runner
```

Then create a pipeline: compile a config with the CLI and `POST` the IR to
`/api/v1/projects/:id/pipelines` (see `web/README.md` — API reference), or
install the GitHub App and just push.

Production deployment: **[DEPLOY.md](DEPLOY.md)** · Remaining work:
**[TODO.md](TODO.md)**

## Architecture

```
GitHub ──push/PR webhook──▶ ┌──────────────────┐
                             │  Control plane   │──claim API──▶ ┌────────────┐
                             │  (Rails 8)       │◀─heartbeats── │   Runner   │
                             │                  │──log chunks──▶│  (Docker)  │
                             │  Postgres        │               └────────────┘
                             │  S3/MinIO        │               ┌────────────┐
                             └──────────────────┘◀─heartbeats── │   Runner   │
                                       │                       │  (Docker)  │
                                       ▼                       └────────────┘
                               commit statuses
                               back to GitHub
```

- **Control plane** owns projects, pipelines, workflow/job state machines,
  the GitHub App, and the polling APIs. Runners never accept inbound
  connections — they poll and claim work, Buildkite-style.
- **Runners** are dumb and disposable: claim → `docker run` → stream logs →
  report. Scale by adding hosts.
- **Config compatibility**: `.circleci/config.yml` (v2.1 subset) is compiled
  server-side into a normalized IR, mirroring CircleCI's own
  `configs/compile` semantics. See the supported-subset table below.

## Repository layout

| Path | What | Component |
|---|---|---|
| `/` (this dir) | `forge-ci` gem: config **compiler** + CLI | 1 |
| `web/` | Rails control plane: intake, claim API, GitHub App, log streaming, cache/artifacts, contexts | 2, 3, 4, 6, 7, 8 |
| `runner/` | Docker runner daemon (stdlib-only Ruby) | 5 |
| `TODO.md` | Remaining work, honestly listed | — |
| `DEPLOY.md` | Production deployment guide | — |

Each part has its own README with setup, API, and env vars:
[`web/README.md`](web/README.md) · [`runner/README.md`](runner/README.md)

## Component status

| # | Component | Status |
|---|---|---|
| 1 | Config compiler (pure function: parse → validate → interpolate → DAG → IR) | ✅ shipped as the `forge-ci` gem |
| 2 | Rails control plane (projects, pipelines, state machines, REST API, web UI) | ✅ |
| 3 | GitHub App (HMAC webhooks, config fetch at SHA, commit statuses, fork-PR secret gating) | ✅ code done — [app registration is manual](web/README.md#github-app-setup-component-3) |
| 4 | Polling runner claim API (atomic claim, heartbeats, reclaim-on-timeout) | ✅ |
| 5 | Docker runner (poll → `docker run` + sidecars → step exec → report) | ✅ |
| 6 | Log streaming (chunked upload → object storage, SSE live tail) | ✅ |
| 7 | Cache + artifacts (S3-compatible, signed URLs, key fallback) | ✅ |
| 8 | Contexts/secrets (encrypted at rest, env injection, masking, rotation, fork gating) | ✅ |

Deliberately deferred: `machine`/`macos`/`windows` executors, orb registry,
dynamic config, `parallelism`/test splitting, cron pipelines, SSH re-run.
Full list in [TODO.md](TODO.md).

## The gem (config compiler)

`forge-ci` compiles CircleCI v2.1-style pipeline YAML into a normalized,
JSON-serializable **intermediate representation (IR)** that the control plane
and runner execute. Pure Ruby, **stdlib only** — no network, no processes, no
dependencies. Tested on Ruby 3.2.3+ (requires >= 3.0).

### Install

```ruby
# Gemfile
gem "forge-ci"
```

Or build locally:

```sh
gem build forge-ci.gemspec
gem install ./forge-ci-0.1.0.gem
```

### Usage

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

### CLI

The gem ships a `forge-ci` executable (pure stdlib, no extra gems):

```sh
# Validate a config: exit 0 if valid, 1 otherwise.
forge-ci validate .circleci/config.yml

# Compile a config to its IR as JSON (pretty-printed by default).
forge-ci compile .circleci/config.yml --branch main --sha abc123 --number 42

# Compact JSON output:
forge-ci compile .circleci/config.yml --json
```

On failure, each error goes to stderr with its YAML line number:

```sh
$ forge-ci validate broken.yml
forge-ci: broken.yml: line 17: workflows.main.jobs: dependency cycle detected: a -> b -> a
$ echo $?
1
```

`compile` returns `[ir, errors]`. `errors` is empty on success; `ir` is `nil`
when errors are present. `ForgeCI::Error` is raised **only** when the YAML text
cannot be parsed at all — everything else (unknown keys, bad references,
dependency cycles) comes back as error strings.

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
            environment: { "NODE_ENV" => "test" },
            secondary_images: [{ image: "redis:7", name: "redis", environment: {} }],
            resource_class: "medium"
          },
          working_directory: "~/project",
          steps: [
            { type: "checkout" },
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

### Supported subset vs CircleCI

| CircleCI v2.1 feature | forge-ci v1 |
|---|---|
| `version: 2.1` | ✅ |
| `parameters:` (string/boolean/integer/enum, defaults, overrides) | ✅ |
| `commands:` reusable steps with parameters | ✅ (inlined at compile time) |
| `executors:` reusable executors with parameters | ✅ (inlined; job-level keys win) |
| `jobs:` with `docker:` executor (primary + service images) | ✅ |
| `working_directory`, `environment`, `resource_class` | ✅ |
| Steps: `checkout`, `run`, `save_cache`, `restore_cache`, `persist_to_workspace`, `attach_workspace`, `store_artifacts`, `store_test_results`, `add_ssh_keys` | ✅ (last two: runner skips loudly, see below) |
| `run:` shorthand, `when: on_success/on_fail/always` | ✅ |
| `when:`/`unless:` conditional steps | ✅ (evaluated at compile time) |
| `<< parameters.x >>`, `<< pipeline.git.branch >>`, `<< pipeline.number >>` | ✅ |
| Workflows: `requires` DAG, cycle detection, topological order | ✅ |
| `filters: branches: only/ignore` (plain names and `/regex/`) | ✅ |
| `matrix:` (desugared to `job-0`, `job-1`, …; alias usable in `requires`) | ✅ |
| `orbs:` | ❌ rejected with a clear error (no registry in v1) |
| `machine:` / `macos:` executors | ❌ rejected with a clear error (Docker only) |
| `type: approval` jobs | ❌ rejected with a clear error |
| Dynamic config (`setup:` workflows) | ❌ not yet supported |
| Docker layer caching, `parallelism` / test splitting | ❌ not yet supported |
| `filters: tags:` | ⚠️ parsed, ignored with a warning |
| Missing `workflows:` | ⚠️ implicit `default` workflow with a warning |

Cache `keys:` templates (e.g. `{{ checksum "package.json" }}`) are passed
through untouched — checksum expansion is a runner concern.

### Design notes

- **Compile is a pure function.** YAML text in, IR out. No I/O, no network,
  no Docker — the whole thing is unit-testable offline.
- **Validation is compilation.** Like CircleCI's own `configs/compile`
  endpoint, there is no separate "validate then run" — one pass collects every
  structural problem with file locations.
- **Errors, not exceptions.** The only raise is `ForgeCI::Error` on
  unparseable YAML. Error strings carry Psych line numbers where the AST can
  locate the key.
- **Warnings vs errors.** Anything that changes what runs (unknown step,
  cycle, bad reference) is an error. Anything informational lands in
  `ir[:meta][:warnings]`.

## Development

```sh
rake test          # gem suite, fixtures in test/fixtures/
cd web && bin/rails test
cd runner && rake test
```

## Contributing

PRs welcome. Keep the zero-dependency philosophy for the gem and the runner
(stdlib only). The control plane is a standard Rails 8 app. Please include
tests — every component ships with its suite green.

## License

MIT — see [MIT-LICENSE](MIT-LICENSE).
