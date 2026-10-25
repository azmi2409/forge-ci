---
name: forge-ci
description: Work with a repository's forge-ci pipeline (.circleci/config.yml run by a self-hosted ForgeCI server) — writing or changing CI jobs, validating the config, starting, watching or cancelling a pipeline, splitting tests, and reading results. Use when a change touches .circleci/config.yml, or when asked to run, debug or check CI on forge-ci.
---

# forge-ci

[ForgeCI](https://github.com/azmi2409/forge-ci) is self-hosted CI/CD that runs
CircleCI 2.1 configs. This repository's pipeline is `.circleci/config.yml`.
A control plane compiles it on every push and pull request (through the
ForgeCI GitHub App) and Docker runners on the team's own machines run the
jobs. Results appear as a `forge-ci` commit status.

## Writing `.circleci/config.yml`

Write standard CircleCI 2.1. These are the differences that matter:

- **Supported:** Docker executors with service containers, `executors:`,
  `commands:`, `parameters:`, workflows with `requires`, `matrix`, branch
  filters (`only`/`ignore`, plain names or `/regex/`), contexts, caches,
  workspaces, artifacts, `when:`/`unless:` and `when: always|on_fail` steps,
  `no_output_timeout`, `parallelism`.
- **Rejected with an error:** orbs, `machine`/`macos`/`windows` executors,
  `type: approval` jobs, dynamic config (`setup:`). Don't use them; write the
  steps out instead of using an orb.
- **Ignored with a warning:** `filters: tags:`. `store_test_results` and
  `add_ssh_keys` validate but the runner skips them.
- **Docker inside a job:** `setup_remote_docker` gives the job the runner
  machine's own Docker daemon (`docker build`, `docker run`, Kamal). Only
  runners set up with `ALLOW_DOCKER_SOCKET=1` accept it, normally just the
  deploy runner, so use it only on jobs with that runner's `resource_class`;
  elsewhere the job fails with an error. Pull requests from forks never get
  it. `version:` is accepted and ignored. `docker_layer_caching: true` keeps
  the image layer cache in a registry, if the server has
  `FORGE_CI_BUILD_CACHE_REGISTRY`: build with `forge-ci-build` (it takes
  `docker build` arguments), or point Kamal's `builder: cache: image:` at
  `FORGE_CI_BUILD_CACHE_IMAGE`. Without the server setting the job logs a
  warning and builds uncached.
- **Lists, not strings:** `branches: only: [main]`, not `only: main`.
- **Absolute paths:** the runner expands `~` to `/root`, but `cimg/*` images
  run as the `circleci` user. Use `/home/circleci/project` for
  `working_directory` and absolute cache `paths`.
- **Shell:** steps run under `/bin/bash -eo pipefail` when the image has bash.
  Each step is a new shell, so pass values on with
  `echo 'export NAME=value' >> "$BASH_ENV"`.
- **Variables:** `CI`, `CIRCLECI`, `CIRCLE_BRANCH`, `CIRCLE_SHA1`,
  `CIRCLE_JOB`, `CIRCLE_BUILD_NUM`, `CIRCLE_WORKFLOW_ID`,
  `CIRCLE_NODE_INDEX`, `CIRCLE_NODE_TOTAL`, `CIRCLE_WORKING_DIRECTORY`,
  `CIRCLE_REPOSITORY_URL`, `CIRCLE_PROJECT_USERNAME`,
  `CIRCLE_PROJECT_REPONAME`. Others such as `CIRCLE_PR_NUMBER` and
  `CIRCLE_TAG` are not set.
- **Timeouts:** a step is killed after 10 minutes without output (raise it
  per step with `no_output_timeout:`), a job after 1 hour.
- **Secrets** belong in the project's environment variables (the project
  page in the ForgeCI dashboard) or a context, never in the config. Every job
  gets them; a job's own `environment:` wins over project variables and
  contexts win over both. Pull requests from forks get neither.

### Runners and `resource_class`

A job's `resource_class` chooses which runners may run it within its trust
pool: a runner claims matching classes plus classless jobs. Trusted tokens
never claim fork jobs; `fork_only` tokens never claim trusted jobs, even when
classes match or are omitted. Keep the classes this repository already uses;
a class with no eligible runner leaves jobs queued.

Fork jobs require dedicated, isolated hosts provisioned with a fork-only
token from **Settings → Runners**. Never route them onto deploy hosts, share
host storage, or reuse their hosts for trusted jobs without rebuilding.
Resource classes are routing labels, not a security boundary. Fork caches
are separate from trusted caches; fork checkout is anonymous GitHub-only,
without installation tokens or operator-configured repository URLs. Private
fork checkout can fail; never work around it by injecting privileged tokens.

### Splitting tests

`parallelism: N` runs N copies of a job. Every job container has a `circleci`
helper:

```yaml
parallelism: 4
steps:
  - run: |
      circleci tests glob "test/**/*_test.rb" |
        circleci tests run --split-by=filesize --command="xargs bin/rails test"
```

- `circleci tests glob` lists files (`**` works); `circleci tests split
  --split-by=name|filesize` prints this copy's share; `circleci tests run`
  pipes the share to `--command` and skips it when the share is empty.
- Prefer `tests run` over `cmd $(circleci tests split)`: an empty share would
  run the command with no arguments, which for many test runners means the
  whole suite.
- `--split-by=timings` is accepted but falls back to `filesize`.
- Jobs that require a parallel job wait for every copy; one failed copy fails
  the job.

## Validate before you commit

The CLI needs only Ruby 3.0+. If `forge-ci` isn't installed, install it with
`gem install forge-ci`. If you can't install gems, run it from a checkout:

```sh
git clone --depth 1 https://github.com/azmi2409/forge-ci.git /tmp/forge-ci
alias forge-ci="ruby -I/tmp/forge-ci/lib /tmp/forge-ci/exe/forge-ci"
```

```sh
forge-ci validate .circleci/config.yml                    # must print "valid"
forge-ci compile .circleci/config.yml --branch main       # the jobs that will run on main
forge-ci compile .circleci/config.yml --branch my-feature # ...and on a branch
```

Treat any warning in `compile`'s `"meta": {"warnings": [...]}` as a bug in the
config. Compile for both the default branch and a feature branch when you
change filters, and check that deploy-like jobs only appear where intended.
Run the commands you changed locally too: forge-ci runs exactly those
commands in the job images.

## Run, watch and cancel

Pipelines normally start on push. For manual runs, sign in with your web-UI
account. Triggering requires an admin; members can view and cancel.

```sh
export FORGE_CI_URL=https://ci.example.com
forge-ci login
# Over SSH/headless: forge-ci login --manual

# Starts a pipeline for the current branch and HEAD; push the commit first.
# --wait blocks and exits non-zero on failure.
forge-ci trigger .circleci/config.yml --project owner/repo --wait
forge-ci cancel <id>
forge-ci logout
```

Login uses authorization-code + PKCE. Credentials live per server in
`~/.config/forge-ci/credentials.json` (0600), or `FORGE_CI_CREDENTIALS`;
`XDG_CONFIG_HOME` changes the default config directory. Tokens refresh
automatically. Resolution is `--token` > `FORGE_CI_ADMIN_TOKEN` > stored login.
Never print, commit, read out, or copy credentials into logs. Corrupt files
fail explicitly: do not delete them blindly and lose other server sessions.
Logout revokes the refresh token and removes local credentials; a revocation
warning means server-side access may remain valid.

For automation and direct API calls, obtain the shared admin token securely
from the operator. Stored CLI login is not automatically used by `curl`.
Do not extract it from the credentials file.

```sh
# FORGE_CI_ADMIN_TOKEN must already be injected securely.
curl -s -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" "$FORGE_CI_URL/api/v1/pipelines/<id>"
curl -s -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" "$FORGE_CI_URL/api/v1/projects"
curl -s -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" "$FORGE_CI_URL/api/v1/queue"
```

Projects created by the GitHub App are named `owner/repo`.

**Logs** aren't readable with the admin token; they're in the web UI at
`$FORGE_CI_URL/job_runs/<job id>`. If you can't sign in, ask the user to
paste the failing step's output rather than guessing.

## When a pipeline fails

1. Find the failing job and step in the pipeline status or the UI.
2. Reproduce the step's command locally in the same image when you can.
3. A job stuck in `queued` can mean no runner serves its `resource_class`,
   no runner belongs to its trust pool, project concurrency is full, or
   capacity is starting. Fork jobs require fork-only runners; changing the
   class must never bypass isolation. Check the queue and Settings first.
4. For a canceled or infrastructure-interrupted job, inspect shutdown/release
   messages before retrying. Only rerun work known safe to repeat; never
   automatically rerun a deployment that may already have changed production.

## Repository notes

Add this repository's own rules below: its resource classes, contexts, which
job deploys, and anything an agent must not change without asking.
