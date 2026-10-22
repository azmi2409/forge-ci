<p align="center">
  <img src="web/public/icon.svg" width="72" height="72" alt="ForgeCI logo">
</p>

<h1 align="center">ForgeCI</h1>

<p align="center">
  <strong>CircleCI-compatible CI/CD you run yourself.</strong><br>
  Your <code>.circleci/config.yml</code>, your runners, your storage. Pure Ruby, MIT licensed.
</p>

<p align="center">
  <a href="https://github.com/azmi2409/forge-ci/actions/workflows/ci.yml"><img src="https://github.com/azmi2409/forge-ci/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="MIT-LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%3E%3D%203.0-red.svg" alt="Ruby >= 3.0"></a>
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs welcome"></a>
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#use-it-with-your-repo">Use it with your repo</a> ·
  <a href="#agent-skills">Agent skills</a> ·
  <a href="#supported-subset-vs-circleci">Compatibility</a> ·
  <a href="DEPLOY.md">Deploy</a> ·
  <a href="docs/">Docs</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

![The ForgeCI dashboard](docs/images/dashboard.png)

Push to GitHub → the webhook arrives → your config is compiled → polling
runners claim the jobs → each step runs in Docker → logs stream live and
commit statuses go back to the pull request. Runners need no inbound ports,
and there's no proprietary control plane.

**Status: MVP complete.** All 8 planned components are built and tested
(371 tests across the compiler, control plane and runner, all green). See
[TODO.md](TODO.md) for what's left.

## Highlights

- **Bring your CircleCI config.** `.circleci/config.yml` (v2.1) compiles and
  runs: executors, commands, parameters, workflows, `requires`, `matrix`,
  branch filters, contexts. The compiler mirrors CircleCI's own
  `configs/compile` semantics.
- **Runners anywhere.** Runners poll over outbound HTTPS, so they work behind
  NAT. Route jobs with `resource_class`, for example checks on Spot instances
  and deploys on an on-demand host.
- **Parallel test splitting.** `parallelism: N` plus `circleci tests glob`,
  `split --split-by=name|filesize` and `run`, built into every job container.
- **The CircleCI runtime you expect.** Bash with `-eo pipefail` by default,
  `$BASH_ENV` between steps, `CIRCLE_*` variables, step and job timeouts.
- **Caches, workspaces and artifacts** on S3, with checksum cache keys.
- **Secrets done carefully.** Contexts are encrypted at rest, masked in logs
  and never given to pull requests from forks.
- **GitHub native.** A GitHub App starts pipelines on push and pull request,
  clones private repos with short-lived tokens and posts commit statuses.
- **Scale to zero.** Idle runners remove themselves and the control plane
  scales Auto Scaling Groups back up when jobs queue, so runners cost
  nothing while nobody is pushing.
- **Agent-ready.** A bundled skill teaches Claude Code and other coding
  agents how to write, validate and run your pipeline.
- **Boring technology.** A stdlib-only Ruby gem and runner, one Rails 8 app,
  Postgres and S3. Nothing exotic to operate.

<table>
  <tr>
    <td width="50%"><img src="docs/images/pipeline.png" alt="A pipeline: stages from requires, with a 4-way parallel test job"></td>
    <td width="50%"><img src="docs/images/job.png" alt="A job: steps, live log and details"></td>
  </tr>
  <tr>
    <td align="center"><sub>Pipelines laid out in stages from <code>requires</code>, parallel nodes grouped</sub></td>
    <td align="center"><sub>Jobs with step results and a live log tail</sub></td>
  </tr>
</table>

## Quickstart

Run the whole stack (Postgres, control plane, worker and a runner) with
Docker Compose. Object storage is AWS S3, so create a bucket first
(`aws s3 mb s3://<bucket>`).

```sh
git clone https://github.com/azmi2409/forge-ci && cd forge-ci
cp .env.example .env     # fill in the S3 bucket + credentials and the secrets
openssl rand -hex 32     # put it in .env as RUNNER_TOKEN (shared runner secret)
docker compose up --build -d
docker compose up -d runner
# → http://localhost:3000, sign in with FORGE_CI_UI_USER / FORGE_CI_UI_PASSWORD from .env
```

Just want to check a config? The compiler needs only Ruby ≥ 3.0:

```sh
gem build forge-ci.gemspec && gem install ./forge-ci-0.1.0.gem
forge-ci validate .circleci/config.yml
forge-ci compile .circleci/config.yml --branch main   # print the compiled jobs
```

For production (HTTPS, Postgres, the GitHub App, runners on their own hosts)
follow **[DEPLOY.md](DEPLOY.md)**.

<details>
<summary>Run the parts by hand for development</summary>

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

</details>

## Use it with your repo

**With the GitHub App** (recommended): register and install it (see
[DEPLOY.md](DEPLOY.md#5-github-app)), then push. The first push from a repo
creates its project, every push and pull request starts a pipeline, and
results show up as a `forge-ci` commit status. Private repos are cloned with a
short-lived installation token, sent as an HTTP header only for the fetch, so
it never reaches `.git/config` or your steps.

**Without the App**, drive it from any CI or script. Set
`FORGE_CI_ADMIN_TOKEN` on the server (`openssl rand -hex 32`), then:

```sh
export FORGE_CI_URL=https://ci.example.com FORGE_CI_ADMIN_TOKEN=...

# one-time: a project and (optionally) a secrets context
curl -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"name":"myapp","repo_url":"https://github.com/me/myapp.git"}' $FORGE_CI_URL/api/v1/projects
curl -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"name":"prod","payload":{"DEPLOY_KEY":"..."}}' $FORGE_CI_URL/api/v1/projects/1/contexts

# every run: compile .circleci/config.yml and start a pipeline for the current
# git branch and commit; --wait blocks and exits non-zero on failure
forge-ci trigger .circleci/config.yml --project myapp --context prod --wait
forge-ci cancel 42    # stop a running pipeline
```

For private repos without the App, set `CHECKOUT_REPO_URL` on the runner with
a token embedded (`https://x-access-token:TOKEN@github.com/org/repo.git`) and
leave the project's `repo_url` empty, since a project `repo_url` takes
precedence.

### Runners and resource classes

Every runner sets `RESOURCE_CLASS`, and a job's `resource_class:` decides
which runners may claim it (jobs without one go to any runner). With the
shared `RUNNER_TOKEN`, that's all the setup routing needs:

```yaml
jobs:
  test:   { resource_class: spot,   ... }   # cheap, interruptible runners
  deploy: { resource_class: deploy, ... }   # one on-demand runner with deploy credentials
```

Runners hold no state. A runner that dies stops heartbeating and its job goes
back in the queue after 120s, so you scale by adding hosts. Steps are killed
after `STEP_NO_OUTPUT_TIMEOUT` seconds without output (default 600; a step's
`no_output_timeout:` wins) and jobs after `JOB_TIMEOUT` (default 3600).

### Scale runners to zero

Runners don't need to run all day. Put each resource class in an AWS Auto
Scaling Group with a minimum of 0:
- **Scaling down:** a runner with `IDLE_SHUTDOWN_AFTER=600` that has had no job
  for 10 minutes stops claiming and removes its own instance. A job is never
  cut short.
- **Scaling up:** with `FORGE_CI_AUTOSCALE=spot=ci-spot-runners:4,deploy=ci-deploy-runner:1`
  set, the control plane raises a group as soon as jobs of that class queue.

The first job after a quiet period waits 1–3 minutes for an instance to boot.
Setup, IAM and a ready-made launch-template script are in
[DEPLOY.md](DEPLOY.md#scale-runners-to-zero-aws). Using another cloud?
`GET /api/v1/queue` gives queue depth per class for your own autoscaler.

## Agent skills

ForgeCI ships a skill for coding agents:
[`skills/forge-ci/SKILL.md`](skills/forge-ci/SKILL.md). It tells an agent
how to write `.circleci/config.yml` for ForgeCI (what's supported, absolute
paths, resource classes, test splitting), validate it before committing, and
start, watch and cancel pipelines. Install it in each repository that ForgeCI
builds.

**Claude Code.** Install it as a project skill, so everyone working in the
repository gets it, and commit it:

```sh
forge-ci skill install                    # writes .claude/skills/forge-ci/SKILL.md
git add .claude/skills/forge-ci && git commit -m "Add the forge-ci agent skill"
```

- **Just for you, in every repository:** `forge-ci skill install --dir ~/.claude/skills`.
- **Without the gem installed:**

  ```sh
  mkdir -p .claude/skills/forge-ci
  curl -fsSL https://raw.githubusercontent.com/azmi2409/forge-ci/main/skills/forge-ci/SKILL.md \
    -o .claude/skills/forge-ci/SKILL.md
  ```

Claude loads it whenever a task touches the pipeline, or when you type
`/forge-ci`.

**Other agents** (Codex, Cursor, GitHub Copilot and anything else that reads
an instructions file): append the skill to that file.

```sh
forge-ci skill show >> AGENTS.md                         # Codex, and agents that read AGENTS.md
forge-ci skill show >> .github/copilot-instructions.md   # GitHub Copilot
```

**Make it yours.** The skill ends with a "Repository notes" section. Write
that repository's rules there: its resource classes, contexts, which job
deploys, and what an agent must not change without asking. Agents read them
with everything else. `forge-ci skill install --force` updates the skill but
replaces the file, so copy your notes back in afterwards.

## Example

```yaml
# .circleci/config.yml
version: 2.1

executors:
  ruby:
    docker:
      - image: cimg/ruby:3.3
      - image: cimg/postgres:16.4   # service container, reachable by its name
    working_directory: /home/circleci/project

jobs:
  test:
    executor: ruby
    resource_class: spot
    parallelism: 4
    steps:
      - checkout
      - restore_cache:
          keys:
            - gems-v1-{{ checksum "Gemfile.lock" }}
      - run: bundle config set path vendor/bundle && bundle install
      - save_cache:
          key: gems-v1-{{ checksum "Gemfile.lock" }}
          paths:
            - vendor/bundle
      - run:
          name: Run tests (a quarter of the files on each node)
          command: |
            circleci tests glob "test/**/*_test.rb" |
              circleci tests run --split-by=filesize --command="xargs bin/rails test"
      - store_artifacts:
          path: coverage

  deploy:
    executor: ruby
    resource_class: deploy
    steps:
      - checkout
      - run: ./bin/deploy

workflows:
  ci:
    jobs:
      - test
      - deploy:
          requires: [test]
          context: [production]
          filters:
            branches:
              only: [main]
```

```sh
$ forge-ci validate .circleci/config.yml
forge-ci: .circleci/config.yml: valid
```

Use absolute paths in `working_directory` and cache `paths`: forge-ci expands
`~` to `/root`, while `cimg` images run as the `circleci` user.

## Architecture

```
GitHub ──push/PR webhook──▶ ┌──────────────────┐
                             │  Control plane   │──claim API──▶ ┌────────────┐
                             │  (Rails 8)       │◀─heartbeats── │   Runner   │
                             │                  │──log chunks──▶│  (Docker)  │
                             │  Postgres        │               └────────────┘
                             │  AWS S3          │               ┌────────────┐
                             └──────────────────┘◀─heartbeats── │   Runner   │
                                       │                       │  (Docker)  │
                                       ▼                       └────────────┘
                               commit statuses
                               back to GitHub
```

- **Control plane** owns projects, pipelines, workflow and job state machines,
  the GitHub App, the web UI and the polling APIs. Runners never accept
  inbound connections: they poll and claim work, Buildkite-style.
- **Runners** are dumb and disposable: claim → `docker run` → stream logs →
  report. Scale by adding hosts.
- **Config compatibility**: `.circleci/config.yml` (v2.1 subset) is compiled
  server-side into a normalized IR, mirroring CircleCI's own
  `configs/compile` semantics. See the supported-subset table below.

Deep dive: [docs/architecture.md](docs/architecture.md)

## Documentation

| Doc | What |
|---|---|
| [docs/architecture.md](docs/architecture.md) | System design: compiler stages, state machines, claim protocol, secrets model |
| [docs/api.md](docs/api.md) | Full v1 API reference + runner contract checklist |
| [docs/configuration.md](docs/configuration.md) | Every environment variable, per component |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and fixes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Dev setup, tests, UI work, PR process |
| [DEPLOY.md](DEPLOY.md) | Production deployment guide |
| [TODO.md](TODO.md) | Remaining work, honestly listed |

## Repository layout

| Path | What | Component |
|---|---|---|
| `/` (this dir) | `forge-ci` gem: config **compiler** + CLI | 1 |
| `web/` | Rails control plane: intake, claim API, GitHub App, log streaming, cache/artifacts, contexts | 2, 3, 4, 6, 7, 8 |
| `runner/` | Docker runner daemon (stdlib-only Ruby), systemd unit, AWS launch-template script | 5 |
| `skills/` | The `forge-ci` agent skill for Claude Code and other coding agents | — |
| `docs/` | Architecture, API, configuration, troubleshooting, screenshots | — |
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
dynamic config, timing-based test splitting, cron pipelines, SSH re-run.
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

# Start a pipeline on a server, wait for it, cancel one:
forge-ci trigger .circleci/config.yml --project owner/repo --wait
forge-ci cancel 42

# Install the agent skill (see "Agent skills"), or print it:
forge-ci skill install [--dir .claude/skills] [--force]
forge-ci skill show
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
| `parallelism: N` (N nodes, `CIRCLE_NODE_INDEX`/`TOTAL`, dependents wait for all) | ✅ |
| `circleci tests glob` / `split --split-by=name\|filesize` / `run` | ✅ (built-in helper in every job container; `timings` falls back to `filesize`) |
| Docker layer caching | ❌ not yet supported |
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
rake test                                                  # compiler gem
cd web && DATABASE_URL="sqlite3:db/test.sqlite3" bin/rails test   # control plane
cd runner && rake test                                     # runner
```

## Contributing

PRs are welcome, against `main` with all three suites green. Start with
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, conventions and how to work on
the UI, and [TODO.md](TODO.md) for where help is needed.

## License

MIT — see [MIT-LICENSE](MIT-LICENSE).
