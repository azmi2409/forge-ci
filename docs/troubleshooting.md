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
running (inside Puma in the Docker image: look for `SolidQueue` lines in
`docker compose logs web`; `bin/jobs` in development). Then check the runner host: `journalctl -u
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

## `exe/forge-ci` isn't executable after checkout

`git` preserves the mode, but some copy flows don't. `chmod +x exe/forge-ci`
(and `web/bin/*`, `runner/bin/forge-ci-runner`).

## Can't sign in / lost the admin password

Run `bin/rails forge_ci:reset_admin` in the control-plane container
(`docker compose exec web bin/rails forge_ci:reset_admin`, or the Terminal tab
on Coolify). It gives the first admin a new password and prints it, creating
an `admin` user if there are none. To set a password of your own, use
`FORGE_USERNAME=admin FORGE_PASSWORD=... bin/rails forge_ci:create_user`.
