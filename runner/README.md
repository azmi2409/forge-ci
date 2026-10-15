# forge-ci-runner

The **Docker runner** for ForgeCI (MVP component 5) — a small daemon that
polls the control plane, claims jobs, and executes them in Docker containers.

Pure Ruby, **stdlib only** (`net/http`, `json`, `open3`, `openssl`,
`shellwords`, `securerandom`, `time`) — no gems. The `docker` CLI is shelled
out to via `Open3` with argv arrays (never through a shell). Tested on
**Ruby 3.2.3** (requires >= 3.0).

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
   - `checkout` — `git init` + fetch the pipeline SHA (see below).
   - `run` — `docker exec` with the step's `shell` (default `/bin/sh -c`),
     environment, and working directory; stdout/stderr streamed as
     seq-numbered log chunks. `when: on_success/on_fail/always` is
     evaluated at runtime: a non-zero exit skips remaining `on_success`
     steps, `on_fail`/`always` steps still run, the job is marked `failed`.
   - `save_cache` / `restore_cache` / `store_artifacts` /
     `persist_to_workspace` / `attach_workspace` / `store_test_results` /
     `add_ssh_keys` — need component 7 (object storage); **skipped loudly
     with a warning, never failed** (failing would be lying about the job).
5. Always cleans up: `docker rm -f` the primary + service containers and
   removes the network, in `ensure` blocks — even on failure or signal.

**Secret redaction** is the runner's job (per the project plan): every
environment value at or above `REDACT_MIN_LENGTH` characters is redacted
from all log chunks before POSTing, exact-substring, longest-first.

**Failure semantics:** step non-zero → `failed`; SIGTERM/SIGINT → finish the
in-flight step, skip the rest, report `canceled`, exit cleanly (no new
claims). A crashed runner simply stops heartbeating and the server reclaims
the job after 120s.

## Setup

```sh
CONTROL_PLANE_URL="https://ci.example.com" \
RUNNER_TOKEN="<raw token from RunnerToken.generate!>" \
RESOURCE_CLASS="medium" \
  bin/forge-ci-runner
```

The binary fails fast if `CONTROL_PLANE_URL`/`RUNNER_TOKEN` are missing or
if `docker info` fails.

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `CONTROL_PLANE_URL` | yes | — | Base URL of the control plane |
| `RUNNER_TOKEN` | yes | — | Raw runner token (Bearer auth) |
| `RESOURCE_CLASS` | no | token's class | Passed to the claim endpoint |
| `POLL_INTERVAL` | no | `5` | Idle poll interval, seconds (backoff base) |
| `MAX_IDLE_INTERVAL` | no | `60` | Idle backoff cap, seconds |
| `HEARTBEAT_INTERVAL` | no | `15` | Heartbeat interval while running, seconds (server reclaims after 120s) |
| `LOG_CHUNK_SIZE` | no | `65536` | Bytes per log chunk |
| `CHECKOUT_REPO_URL` | no | — | Git URL for `checkout`; may embed a token: `https://x-access-token:TOKEN@github.com/org/repo.git` |
| `REDACT_MIN_LENGTH` | no | `8` | Env values shorter than this are not redacted |
| `DOCKER_BIN` | no | `docker` | Path to the docker CLI |

## Control-plane contract

Built exactly against the Runner API documented in `web/README.md`
("API reference (v1)" + "Runner contract"):

- `POST /api/v1/runner/jobs/claim` → `200` job payload or `422` (idle)
- `POST /api/v1/runner/jobs/:id/start`
- `POST /api/v1/runner/jobs/:id/heartbeat`
- `POST /api/v1/runner/jobs/:id/complete` with `{status, step_results}` —
  step names follow the server convention `step["name"] || step["type"]`
- `POST /api/v1/jobs/:id/log_chunks` with `{seq, chunk}` (idempotent)

No endpoints invented; nothing else assumed.

### Contract gaps (found while building)

1. **The claim payload carries no repo URL or checkout token.**
   `pipeline` is `{sha, branch}` only. `checkout` therefore clones from
   `CHECKOUT_REPO_URL` when set, and otherwise skips with a loud warning.
   Future contract should include `pipeline.repo_url` plus a short-lived
   checkout token.
2. **Secrets are not distinguished from plain env vars.** The payload
   merges executor env with context payloads ("contexts win") with no
   marker for which values are secrets, so the runner redacts *all*
   values ≥ `REDACT_MIN_LENGTH` chars. A future contract should return an
   explicit secret key list.
3. **Step name collisions.** The server matches `step_results` to StepRuns
   by name (`find_by`); two steps with the same name update the same
   record (last write wins). The runner reports every step once.

## Tests

```sh
rake test
```

45 runs, 134 assertions. The one Docker-dependent integration test
(`hello-world` container) skips gracefully when `docker info` fails —
pure logic (payload handling, `when` evaluation, redaction, backoff,
cleanup ordering, HTTP contract) is fully covered without Docker.

## Not yet (deferred)

- Cache / artifact / workspace upload/download on object storage (component 7)
- Per-step timeouts (a hung step hangs until the process is killed)
- CPU/memory resource limits on containers
- Multi-arch image selection
- `machine` / `macos` executors (Docker only in v1)
- The `~` in `working_directory` is expanded to `/root` (assumes
  containers run as root, true for virtually all CI images)

## License

MIT — same as the `forge-ci` gem. Copyright (c) 2026 Azmi Muwahid.
