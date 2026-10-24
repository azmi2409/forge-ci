# The compiler gem and CLI

`forge-ci` compiles CircleCI v2.1-style pipeline YAML into a normalized,
JSON-serializable **intermediate representation (IR)** that the control plane
and runner execute. Pure Ruby, **stdlib only** — no network, no processes, no
dependencies. Tested on Ruby 3.2.3+ (requires >= 3.0).

## Install

```sh
gem install forge-ci   # the `forge-ci` CLI lands on your PATH
```

Or as a library:

```ruby
# Gemfile
gem "forge-ci"
```

From a checkout of this repo, `rake install` builds and installs the gem from
source (`rake build` just produces the `.gem`; `rake release` pushes a new
version to RubyGems).

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

## CLI

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

## IR shape

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

## Supported subset vs CircleCI

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
| `setup_remote_docker` | ✅ the job uses the runner machine's Docker daemon. Only runners with `ALLOW_DOCKER_SOCKET=1` accept it, and never for fork pull requests; `version` is ignored |
| Docker layer caching | ✅ `docker_layer_caching: true` under `setup_remote_docker` opts into the registry-backed layer cache (`FORGE_CI_BUILD_CACHE_REGISTRY` on the server; see docs/configuration.md) — without it, layers stay on the runner's daemon until the machine goes |
| `filters: tags:` | ⚠️ parsed, ignored with a warning |
| Missing `workflows:` | ⚠️ implicit `default` workflow with a warning |

Cache `keys:` templates (e.g. `{{ checksum "package.json" }}`) are passed
through untouched — checksum expansion is a runner concern.

## Design notes

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
