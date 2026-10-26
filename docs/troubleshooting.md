# Troubleshooting

## Pushed, but no pipeline appeared

1. Is the GitHub App installed on the repo's account/org? (Settings → GitHub
   Apps — the install must cover the repo.)
2. Is the control plane reachable at its **public** HTTPS URL? GitHub can't
   deliver webhooks to localhost. Check the App's *Recent Deliveries* tab for
   failed attempts.
3. Does the repo have `.circleci/config.yml` **at the pushed SHA**? Repos
   without a config file are skipped quietly, by design.
4. Did the config fail to compile? That creates a **failed** pipeline with a
   `failure` commit status — check the UI and the status message.

## Webhook deliveries return 401

`GITHUB_WEBHOOK_SECRET` doesn't match the secret configured on the App, or
it's blank — the endpoint is fail-closed and 401s everything when blank.
The secret must be byte-identical on both sides.

## Runner polls but never claims (422 every time)

- **Token**: wrong `RUNNER_TOKEN` → `401`, not 422. If you see 401, regenerate
  the token (`RunnerToken.generate!`) — only the digest is stored, the raw
  value can't be recovered.
- **resource_class mismatch**: the server matches job `resource_class` to the
  token's class (NULL matches anything). If jobs specify `resource_class:
  large` and the token is `medium`, nothing is claimable.
- **max_concurrency**: the project's slot count (default 4) counts
  `claimed` + `running` jobs. A wedged job holds its slot until reclaimed.
- **Nothing queued**: jobs with unmet `requires` stay `pending`, not
  `queued` — check the pipeline view for a failed dependency upstream.

## Job stuck in `claimed` / `running` forever

The runner died without completing. `ReclaimStaleJobsJob` returns jobs with
no heartbeat for 120s to `queued` — check that the Solid Queue worker is
running: `docker compose logs worker` should show `SolidQueue` lines (in
development, run `bin/jobs`). Then check the runner host: `journalctl -u
forge-ci-runner`, `docker ps`.

## Logs stop streaming / SSE disconnects

The live tail holds the connection up to `FORGE_CI_STREAM_TIMEOUT_SECONDS`
(default 300s). Proxies (nginx, Cloudflare) may kill idle SSE connections
earlier — the job page falls back to polling. If *no* chunks ever arrive,
the runner isn't POSTing them: check the runner's connectivity to the
control plane.

## Cache is always a miss

- Key templates resolve **at runtime on the runner**: `{{ checksum "path" }}`
  hashes file *contents* relative to the job's working directory — a missing
  file hashes to the empty string (plus a warning), silently changing your key.
- Restore tries keys in order; the server falls back to longest-prefix. A
  `404` on all keys is a clean miss, not an error.

## Docker layer cache stays cold (every build from scratch)

That's the local layer cache dying with the machine — expected on Spot /
scale-to-zero runners. Turn on the registry-backed cache
(`FORGE_CI_BUILD_CACHE_REGISTRY` on the server +
`docker_layer_caching: true` in the job) and build with `forge-ci-build`
(see docs/configuration.md, "Docker layer caching"). If it is on but still
cold: the job log shows the runner's warnings — "no FORGE_CI_BUILD_CACHE_REGISTRY",
a failed `docker login`, or missing buildx (`BUILDX_BIN` unset and the job
image ships none). `forge-ci-build` also only reuses layers for unchanged
Dockerfile steps; a changed dependency file legitimately rebuilds from there
down.

## Fork PR has no secrets

By design: fork pipelines forcibly receive zero contexts
(`Pipeline#forked`). If a *non-fork* pipeline is missing env vars, check the
project's default contexts and that the context names in the intake payload
exist.

## `bundle install` fails on `path: ".."` (dev)

The web app consumes the compiler as a path gem from the repo root. If you
checked out the components into sibling directories instead of the monorepo
layout, point the `forge-ci` entry in `web/Gemfile` at your local gem dir.

## Docker permission denied on the runner host

The runner shells out to the `docker` CLI — it must run as root or as a user
in the `docker` group, and `docker info` must succeed (the daemon fails fast
otherwise). Set `DOCKER_BIN` if the CLI isn't on `PATH`.

## Switching a Ruby runner to Go

Ruby remains the default on PR #28's `runner-go` branch. Opt in with
`--implementation go` (not `--implementation=go`) using the
[Ruby-to-Go migration runbook](../DEPLOY.md#ruby-to-go-runner-migration).
The Rails control plane stays Ruby; switching runners alone needs no DB change.

- **Canary safety:** switch an idle, non-deploy runner first. Keep one service
  per identity, existing resource-class routing, and separate fork/trusted hosts.
  Never enable requeue for deployments or retry work not known safe to repeat.
- **Settings disappeared:** reinstall rewrites `/etc/forge-ci-runner.env` and
  the systemd unit. Reuse all original installer flags (`--class`,
  `--idle-shutdown`, `--asg`, `--allow-docker`, `--requeue-on-shutdown`) and
  securely restore custom settings such as timeouts, polling, Docker/buildx,
  checkout fallback, and token-file configuration. Do not print env files or
  tokens into terminal recordings, tickets, or logs.
- **Archive has no Go binary / checksum failure:** the root web image builds
  both architectures automatically. Source-only Rails deployments must
  [build binaries and `SHA256SUMS`](../runner-go/README.md#source-only-control-plane-deployments)
  in the `runner/` directory selected by `FORGE_CI_RUNNER_PATH`. Do not bypass
  checksum verification. Download/verification failures precede service swap.
- **Activation failed:** installer attempts to restore the old tree, env,
  unit, and previously running service. Check `systemctl is-active
  forge-ci-runner` and inspect `journalctl -u forge-ci-runner` privately;
  service activation is not evidence of job parity or a completed soak.
- **Rollback:** reinstall with `--implementation ruby`, preserving the same
  flags and custom settings, or restore `/opt/forge-ci-runner.old` together
  with `/etc/forge-ci-runner.env.bak` and
  `/etc/systemd/system/forge-ci-runner.service.bak`, reload systemd, and restart
  the single service. Follow the runbook's exact restore steps. Later installs
  overwrite `.old`/`.bak`; retain independent protected backups first.

## Go timeout skips `on_fail` / `always` steps

Both runners support `STEP_NO_OUTPUT_TIMEOUT=600` and `JOB_TIMEOUT=3600`
(seconds; `0` disables), and a step's `no_output_timeout` overrides the silence
limit. Both report timeout exit code 124. Go applies a job-wide execution
deadline, immediately removes the primary container when interrupted, and
skips every remaining step, including `on_fail`/`always`. Ruby checks deadlines
while streaming commands and kills the client; container-side work stops at
cleanup. Normal command failure still allows failure handlers in both. Do not
depend on timeout handlers for essential cleanup; review the
[behavioral differences](../runner-go/README.md#deliberate-differences-from-the-ruby-runner)
before canarying jobs with long silent steps or slow setup/transfers.

## `exe/forge-ci` isn't executable after checkout

`git` preserves the mode, but some copy flows don't. `chmod +x exe/forge-ci`
(and `web/bin/*`, `runner/bin/forge-ci-runner`).

## Can't sign in / lost the admin password

Run `bin/rails forge_ci:reset_admin` in the control-plane container
(`docker compose exec web bin/rails forge_ci:reset_admin`, or the Terminal tab
on Coolify). It gives the first admin a new password and prints it, creating
an `admin` user if there are none. To set a password of your own, use
`FORGE_USERNAME=admin FORGE_PASSWORD=... bin/rails forge_ci:create_user`.
