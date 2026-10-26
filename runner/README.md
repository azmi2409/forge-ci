# forge-ci-runner

The **Docker runner** for ForgeCI (MVP component 5) — a small daemon that
polls the control plane, claims jobs, and executes them in Docker containers.

Pure Ruby, **stdlib only** (`net/http`, `json`, `open3`, `openssl`,
`shellwords`, `securerandom`, `time`) — no gems. The `docker` CLI is shelled
out to via `Open3` with argv arrays (never through a shell). Tested on
**Ruby 3.2.3** (requires >= 3.0).

Ruby remains the **default runner** on the PR #28 `runner-go` branch. The
[Go runner](../runner-go/README.md) is opt-in with `--implementation go`;
this changes only the runner daemon, not the Ruby/Rails control plane or DB.
Use the [Ruby-to-Go runner migration guide](../DEPLOY.md#ruby-to-go-runner-migration)
for an idle, non-deploy canary, environment preservation, and rollback.

Updated runner processes report presence through idle claim polls and job
heartbeats. Admins see each process in **Settings → Runners**, even with a
shared token. Restart after upgrading; old processes remain compatible but
unlisted. See [presence semantics](../docs/api.md#runner-presence).

## How it works

```
poll claim → start → execute → complete
   │                      │
   │                      ├─ heartbeat every 15s while running
   │                      └─ stream redacted log chunks (seq-numbered)
   └─ 422 (nothing claimable) → idle backoff 5s → 10s → … → 60s cap
```

Per claimed job the runner:

1. Pulls the primary image and any service/secondary images from the executor.
2. Creates an isolated Docker network (`forge-ci-net-<job>-<rand>`).
3. Starts service containers first (reachable by name via network aliases),
   then the primary container (long-lived — steps run via `docker exec`).
4. Executes steps in order:
   - `checkout` — clones `repository.url` from the claim payload (falls back
     to `CHECKOUT_REPO_URL`, then skips loudly) at the pipeline SHA.
   - `run` — `docker exec` with the step's `shell` (default, like CircleCI:
     `/bin/bash -eo pipefail` when the image has bash, else `/bin/sh`),
     environment, and working directory. `$BASH_ENV` points at a file
     created empty at job start that bash sources before each step, so
     `echo 'export X=1' >> "$BASH_ENV"` passes values to later steps.
     CircleCI-style built-ins are set (`CI`, `CIRCLECI`, `CIRCLE_BRANCH`,
     `CIRCLE_SHA1`, `CIRCLE_JOB`, `CIRCLE_BUILD_NUM`, `CIRCLE_WORKFLOW_ID`,
     `CIRCLE_WORKING_DIRECTORY`, `CIRCLE_REPOSITORY_URL`,
     `CIRCLE_PROJECT_USERNAME`/`REPONAME`, `CIRCLE_NODE_INDEX`/`TOTAL`);
     the job's own environment wins on a clash. A `circleci` helper
     (`lib/forge_ci_runner/circleci_cli.sh`) is copied to
     `/usr/local/bin/circleci` in every job container for test splitting:
     `circleci tests glob`, `tests split --split-by=name|filesize|timings`
     (timings falls back to filesize) and `tests run --command=…`, which
     skips the command when a node's share is empty. stdout/stderr streamed as
     seq-numbered log chunks. `when: on_success/on_fail/always` is
     evaluated at runtime: a non-zero exit skips remaining `on_success`
     steps, `on_fail`/`always` steps still run, the job is marked `failed`.
   - `save_cache` / `restore_cache` — tarballs moved between the job
     container and the control plane's cache API. Key templates resolved
     at runtime: `{{ checksum "path" }}` (SHA256 of file contents, relative
     to the working directory; missing file → empty string + warning),
     `{{ .Branch }}`, `{{ epoch }}`; anything else is left as-is with a
     warning. Restore tries keys in order (server: exact, then
     longest-prefix fallback); a clean miss never fails the job.
   - `store_artifacts` — each file under `path` uploaded individually
     (`destination` passed through as the UI prefix).
   - `persist_to_workspace` / `attach_workspace` — implemented on top of
     the cache API under a reserved namespace (see below).
   - `store_test_results` / `add_ssh_keys` — not implemented yet; **skipped
     loudly with a warning, never failed** (failing would be lying about
     the job).
5. Always cleans up: `docker rm -f` the primary + service containers and
   removes the network, in `ensure` blocks — even on failure or signal.

**Secret redaction** is the runner's job (per the project plan): every
environment value at or above `REDACT_MIN_LENGTH` characters is redacted
from all log chunks before POSTing, exact-substring, longest-first.

**Failure semantics:** step non-zero → `failed`; SIGTERM/SIGINT → finish the
in-flight step, skip the rest, report `canceled`, exit cleanly (no new
claims). A crashed runner simply stops heartbeating and the server reclaims
the job after 120s.

With `REQUEUE_ON_SHUTDOWN=1` (Spot runners), SIGTERM/SIGINT instead stops
the in-flight step at once and releases the job (`POST …/release`): it goes
back to the queue and another runner runs it from the start. After
`MAX_RELEASES` (2) releases, or if the release fails, the job is reported
`canceled` as above. Only turn it on where every job is safe to run twice:
never on deploy runners.

## Setup

The easy way is the install command under **Settings → Runners** on the
control plane: `curl -fsSL https://ci.example.com/install-runner | sudo sh -s -- --token …`.
It installs Docker and Ruby, downloads this directory from the control plane
(`/runner.tar.gz`) to `/opt/forge-ci-runner` and starts the
`forge-ci-runner` systemd service.

To switch an existing host, do not append `--implementation go` to a shortened
install command: the installer **rewrites** `/etc/forge-ci-runner.env` and the
systemd unit. Preserve every original flag (class, idle shutdown, ASG, Docker
access, and requeue settings) and restore custom environment settings securely;
never print or commit the token or environment backups. Keep a separate protected
backup before another reinstall overwrites `.old`/`.bak`. Run only one service
per runner identity, and switch only while idle. Full procedure and restoration
of the previous tree, env, and unit: [migration guide](../DEPLOY.md#ruby-to-go-runner-migration).

To run the Ruby runner by hand:

```sh
CONTROL_PLANE_URL="https://ci.example.com" \
RUNNER_TOKEN="<token from Settings → Runners>" \
RESOURCE_CLASS="medium" \
  bin/forge-ci-runner
```

The binary fails fast if `CONTROL_PLANE_URL`/`RUNNER_TOKEN` are missing or
if `docker info` fails.

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CONTROL_PLANE_URL` | yes | — | Base URL of the control plane |
| `RUNNER_TOKEN` | yes, or `RUNNER_TOKEN_FILE` | — | Raw runner token (Bearer auth) |
| `RUNNER_TOKEN_FILE` | no | — | File holding the token, read when `RUNNER_TOKEN` is unset |
| `RESOURCE_CLASS` | no | token's class, else any | Passed to the claim endpoint |
| `POLL_INTERVAL` | no | `5` | Idle poll interval, seconds (backoff base) |
| `MAX_IDLE_INTERVAL` | no | `60` | Idle backoff cap, seconds |
| `HEARTBEAT_INTERVAL` | no | `15` | Heartbeat interval while running, seconds (server reclaims after 120s) |
| `LOG_CHUNK_SIZE` | no | `65536` | Bytes per log chunk |
| `LOG_FLUSH_INTERVAL` | no | `1` | Send buffered output at least this often (seconds), so the job page shows it live |
| `CHECKOUT_REPO_URL` | no | — | Git URL for `checkout`; may embed a token: `https://x-access-token:TOKEN@github.com/org/repo.git` |
| `REDACT_MIN_LENGTH` | no | `8` | Env values shorter than this are not redacted |
| `DOCKER_BIN` | no | `docker` | Path to the docker CLI |
| `BUILDX_BIN` | no | — | Path to a buildx binary the runner copies into job images that lack one, for `docker_layer_caching` builds (`docs/configuration.md`, "Docker layer caching"). The install command's `--allow-docker` sets it |
| `STEP_NO_OUTPUT_TIMEOUT` | no | `600` | Seconds a foreground `run` step may stay silent; step `no_output_timeout` overrides it; `0` disables |
| `JOB_TIMEOUT` | no | `3600` | Job wall-clock limit checked while streaming commands; `0` disables. Go additionally applies a context deadline across execution |
| `IDLE_SHUTDOWN_AFTER` | no | `0` (never) | Seconds without a job after which the runner stops claiming, runs `IDLE_SHUTDOWN_COMMAND` and exits (scale to zero) |
| `IDLE_SHUTDOWN_COMMAND` | no | — | Shell command run once on idle shutdown; `bin/forge-ci-asg-terminate-self` removes this EC2 instance from its Auto Scaling Group |
| `ALLOW_DOCKER_SOCKET` | no | off | `1` lets jobs with `setup_remote_docker` use this machine's Docker socket. Such a job controls the machine, so set it only on runners trusted with that (the deploy runner); fork pull requests are always refused. The install command's `--allow-docker` sets it |
| `REQUEUE_ON_SHUTDOWN` | no | off | `1`: on SIGTERM/SIGINT mid-job, stop the running step and put the job back in the queue instead of reporting it canceled (at most twice per job). For Spot/preemptible runners whose jobs are safe to retry; never on deploy runners. The install command's `--requeue-on-shutdown` sets it |
| `DOCKER_SOCKET_PATH` | no | `/var/run/docker.sock` | The socket mounted for `setup_remote_docker` |

## Control-plane contract

Built exactly against the Runner API documented in `web/README.md`
("API reference (v1)" + "Runner contract"):

- `POST /api/v1/runner/jobs/claim` → `200` job payload or `422` (idle)
- `POST /api/v1/runner/jobs/:id/start`
- `POST /api/v1/runner/jobs/:id/heartbeat`
- `POST /api/v1/runner/jobs/:id/complete` with `{status, step_results}` —
  step names follow the server convention `step["name"] || step["type"]`
- `POST /api/v1/jobs/:id/log_chunks` with `{seq, chunk}` (idempotent)
- `POST /api/v1/jobs/:id/artifacts` — multipart `file` + `path` +
  `destination?` → `201` artifact hash
- `PUT /api/v1/projects/:id/cache` — multipart `key` + `file` (tarball) →
  `200 {key, size}`
- `GET /api/v1/projects/:id/cache?keys[]=k1&keys[]=k2` → `200`
  `{key, size, download_url}` or `404`

No endpoints invented; nothing else assumed.

### Contract gaps (found while building)

1. ~~The claim payload carries no repo URL or checkout token.~~ **Resolved:**
   the payload now includes `repository: { url, sha, branch, token }` —
   `token` is a GitHub App installation token, present only for App-backed
   private repos (`CHECKOUT_REPO_URL` remains as fallback).
2. **The claim payload carries no `project_id`.** The cache API is
   project-scoped (`PUT/GET /api/v1/projects/:id/cache`), so `save_cache`,
   `restore_cache`, `persist_to_workspace`, and `attach_workspace` skip
   loudly until the control plane includes `project_id` in the job payload.
3. **Secrets are not distinguished from plain env vars.** The payload
   merges executor env with context payloads ("contexts win") with no
   marker for which values are secrets, so the runner redacts *all*
   values ≥ `REDACT_MIN_LENGTH` chars. A future contract should return an
   explicit secret key list.
4. **Step name collisions.** The server matches `step_results` to StepRuns
   by name (`find_by`); two steps with the same name update the same
   record (last write wins). The runner reports every step once.

### Workspaces

CircleCI has one workspace per workflow. The runner implements it on the
cache API under a reserved namespace:

- `forge-ci-workspace/<workflow_run_id>/<root>.tgz` — one tarball per
  persisted root (`root` sanitized: non-alphanumerics → `-`)
- `forge-ci-workspace/<workflow_run_id>/manifest.json` — JSON list of
  persisted roots, so `attach_workspace` can discover them

`persist_to_workspace` tars `paths` relative to `root` and uploads;
`attach_workspace` downloads every root tarball and extracts them at `at`.
Concurrent persists from parallel jobs can race on the manifest
(last write wins) — acceptable for v1, documented here.

## Tests

```sh
rake test
```

45 runs, 134 assertions. The one Docker-dependent integration test
(`hello-world` container) skips gracefully when `docker info` fails —
pure logic (payload handling, `when` evaluation, redaction, backoff,
cleanup ordering, key templates, tar round-trips, multipart streaming,
cache/artifact/workspace flows against a fake control plane, HTTP
contract) is fully covered without Docker.

## Not yet (deferred)

- `store_test_results` parsing (JUnit → timing DB) and `add_ssh_keys`
- Go-style job-wide deadline enforcement and immediate container removal on timeout:
  Ruby kills the `docker exec` client and cleans up containers at job end;
  Go removes the primary container immediately and skips every remaining step,
  including `on_fail`/`always`. Both report timeout exit code 124. See
  [Go behavioral differences](../runner-go/README.md#deliberate-differences-from-the-ruby-runner).
- CPU/memory resource limits on containers
- Multi-arch image selection
- `machine` / `macos` executors (Docker only in v1)
- The `~` in `working_directory` is expanded to `/root` (assumes
  containers run as root, true for virtually all CI images)

## License

MIT — same as the `forge-ci` gem. Copyright (c) 2026 Azmi Muwahid.
