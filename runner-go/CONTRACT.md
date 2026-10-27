# Runner wire & behavioral contract (frozen)

Baseline: `origin/main` @ `3ec031f` (merge of PR #27; includes fork runner-trust
pools and context-snapshot encryption). Rails side is the source of truth; the
Go runner is built against exactly this and never forces a Rails change to make
a test pass. Fixtures in `contract/` are golden examples; validation against
a real Rails/PostgreSQL control plane remains a [soak gate](SOAK.md), not a
completed-soak claim. Ruby remains the default; Go is opt-in via
`--implementation go`. Runner-only migration needs no Rails or DB change;
see the [operator runbook](../DEPLOY.md#ruby-to-go-runner-migration).

Sources read to produce this: `web/app/controllers/api/v1/runner/jobs_controller.rb`,
`web/app/controllers/api/v1/base_controller.rb`, `web/app/controllers/api/v1/jobs_controller.rb`,
`web/app/controllers/api/v1/cache_controller.rb`, `web/app/controllers/api/v1/artifacts_controller.rb`,
`web/app/models/job_run.rb`, `web/app/models/runner_token.rb`, `web/app/services/build_cache_config.rb`,
`lib/forge_ci/{validator,ir}.rb`, `runner/README.md`.

## Transport & auth

- Base URL from `CONTROL_PLANE_URL` (trailing slashes stripped). All API paths under `/api/v1/`.
- Every control-plane request carries `Authorization: Bearer <token>` (scheme match is
  case-insensitive server-side; send `Bearer`), `Accept: application/json`.
- **Redirects are disabled on the authenticated client.** Only signed-URL downloads
  (separate, unauthenticated client) follow redirects — max 3, http/https only.
- Errors are JSON `{ "error": "..." }` (claim-idle adds `upcoming`).
- Timeout semantics (deliberate, per endpoint class):
  - JSON lifecycle calls: whole-request deadline is fine (Ruby had open 10s / read 60s
    inactivity; a short total deadline is acceptable for these small payloads).
  - Multipart uploads and signed downloads: dial + response-header timeouts only plus a
    context deadline; **never** a short total `Client.Timeout` that can kill a healthy
    long transfer.
- Retry policy: **only log-chunk POSTs are retried** (server upserts on `(job_id, seq)`,
  so a retried POST cannot duplicate). Claim/start/heartbeat/complete/release, cache and
  artifact uploads are **never** blindly retried; callers decide (the runner loop's
  backoff is a new poll, not a retry of an in-flight request).
- Additive presence headers on lifecycle JSON requests are documented in
  [the API reference](../docs/api.md#runner-presence). Each client process has
  one UUID, a hostname and implementation (`go`). Old servers may ignore them;
  upgraded servers use idle polls and job heartbeats for admin status without
  changing the job lifecycle response contract.

## POST /api/v1/runner/jobs/claim

Request: `{ "resource_class": "medium" }` (field omitted when the runner has none).

- `200` → job payload (below).
- `422` → nothing claimable: `{ "error": "no claimable jobs right now", "upcoming": 3 }`.
  `upcoming` remains an additive compatibility field (0 on older servers); current Ruby and
  Go runners use the count-only `GET /api/v1/runner/outlook` for idle linger instead.
  [fixture `claim-upcoming-422.json`]
- `401` → `{ "error": "unauthorized: valid bearer token required" }` — the runner exits
  immediately (bad token never heals by backing off). [fixture `claim-unauthorized-401.json`]

## GET /api/v1/runner/outlook

Runner-token authenticated. Returns counts only for the token's trust pool and the
resource class it may claim, including classless jobs. A class-pinned token's class
wins; a classless token may pass `?resource_class=NAME` (omitted means any class).
The response never includes project, pipeline, or job identifiers:

```json
{ "queued": 0, "running": 0, "pending": 0 }
```

- `queued`: queued jobs eligible for this token and class.
- `running`: claimed or running jobs in the same trust pool and eligible class.
- `pending`: pending jobs in active pipelines/workflows whose required jobs have
  not failed or been canceled. Terminal pipelines/workflows and jobs blocked by a
  failed/canceled prerequisite are excluded.
- Missing or invalid runner credentials return `401`. This endpoint is runner-only;
  admin and personal OAuth credentials do not authenticate it.

The endpoint is a best-effort hint for bounded runner linger, not a claim reservation:
work may become claimable only after the next poll, or disappear before then.

Pool selection (server-side, pinned for regression coverage): fork-only tokens run only
fork pipelines; every other token runs only trusted pipelines; a NULL class on either side
matches anything; project `max_concurrency` gates claims. The runner cannot influence this
beyond passing its `resource_class`.

### Job payload

Built with Rails `.compact` — **nil top-level fields are ABSENT, not null**. The one
known non-compacted nested null: `artifact` JSON's `destination` (see Artifacts).
Go structs use pointer fields wherever absence ≠ zero and must tolerate every fixture.

| Field | Type | Present | Notes |
|---|---|---|---|
| `id` | number | always | |
| `name` | string | always | |
| `node_index` | number | when set | default 0 |
| `parallelism` | number | when set | default 1 |
| `working_directory` | string | when set | `~/` expands to `/root/` |
| `executor` | object | when set | `{ image, entrypoint?, command?, environment?, resource_class?, secondary_images? }`; all but `image` may be missing/null |
| `steps` | array | always (`[]`) | ordered IR steps; may contain shapes unknown to the runner |
| `environment` | object | when set | values are strings (stringify anything else defensively) |
| `secret_values` | string array | current server | project-variable/context values effective in the job environment; `[]` for forks. Older servers omit it; runners treat absence as empty |
| `pipeline` | object | always | `{ sha, branch }` (either may be null) |
| `trusted` | bool | current server | **missing = trusted** (older servers); `false` = fork PR. Runner refuses `setup_remote_docker` only when exactly `false` |
| `workflow_run_id` | number | when set | workspace namespace key |
| `project_id` | number | when set | required by cache/workspace/artifact-of-cache steps; without it they skip loudly |
| `repository` | object | when a URL is known | `{ url, sha?, branch?, token? }`; `token` (GitHub App installation token) omitted when none — used ONLY as an `http.extraHeader` on the fetch exec |
| `docker_build_cache` | object | when configured & requested | `{ registry, ref, username?, password? }` — username/password omitted for unauthenticated registries |

Fixtures: `claim-full.json` (everything present), `claim-classless.json`,
`claim-fork.json` (`"trusted": false`, empty `secret_values`, no `docker_build_cache`, no repository token),
`claim-trusted-absent.json` (older-server shape: no `trusted`, no `project_id`,
no `workflow_run_id`, no `docker_build_cache`).

### Steps (IR shapes emitted by the compiler)

`STEP_TYPES = checkout run save_cache restore_cache persist_to_workspace
attach_workspace store_artifacts store_test_results add_ssh_keys setup_remote_docker`.

- `run`: `{ type, name?, command, shell?, background(bool, default false), when("on_success"|"on_fail"|"always", default on_success), environment?, no_output_timeout? }`.
  Display name convention everywhere: `name || type || "step"` — must match what the server
  stored in StepRuns (`complete_with_results!` matches `step_results[].name` via `find_by`).
- `checkout`: `{ type, path? }`.
- `save_cache`: `{ type, keys|key, paths }`; `restore_cache`: `{ type, keys }`.
- `persist_to_workspace`: `{ type, root, paths }`; `attach_workspace`: `{ type, at }`.
- `store_artifacts`: `{ type, path, destination? }`.
- `store_test_results` / `add_ssh_keys`: not implemented — **skipped loudly, exit 0**.
- Unknown types: skipped loudly with the type in the warning, exit 0.
- Step dicts keep their raw JSON in Go (`json.RawMessage` per step) so unknown steps can
  be identified and reported by name/type without failing to decode.

## Lifecycle endpoints (all JSON)

| Call | Success | Errors the runner must handle |
|---|---|---|
| `POST /runner/jobs/:id/start` | `{ id, status: "running" }` | `422` IllegalTransition (e.g. reclaimed after heartbeat loss) |
| `POST /runner/jobs/:id/heartbeat` | `{ id, status, heartbeat_at }` | `403` non-owner, `404` unknown; reply `status == "canceled"` = stop the job |
| `POST /runner/jobs/:id/complete` `{ status, step_results }` | `{ id, status }` | `422` IllegalTransition |
| `POST /runner/jobs/:id/release` `{ reason }` | `{ id, status: "queued" }` | `409` released `MAX_RELEASES`(=2) times already; `422` IllegalTransition |

- `status` on complete: `"success" | "failed" | "canceled"` (terminal set server-side).
- `step_results[]`: `{ name, exit_code, started_at, finished_at }` — timestamps RFC3339 UTC
  with second precision (`2026-10-25T09:30:12Z`, matching Ruby `Time#iso8601` on a UTC time).
  `exit_code.to_i.zero?` → step success server-side.
- Idempotency: none of these are idempotent — complete/release/start fire **once**; a lost
  response is not retried (a released job must never continue executing locally regardless
  of whether the release response arrived).
- Heartbeat cadence ≤ 120s (`STALE_HEARTBEAT_AFTER`); Ruby default 15s. A claimed-but-never-
  started job is requeued by the server's stale reaper; a running one is failed.

## POST /api/v1/jobs/:id/log_chunks

`{ "seq": N, "chunk": "..." }` → `200 { job_id, seq }`. Upsert on `(job_id, seq)` — safe to
retry the same seq. **`chunk` must be non-empty** (server rejects blank with `422` — an empty
chunk is never sent). Seqs strictly increasing per job; a retried POST reuses its seq.
[fixtures `log-chunk-ok.json`, `log-chunk-422.json`]

## Cache API (project-scoped)

- `PUT /api/v1/projects/:id/cache` — multipart `key` + `file` (tarball) → `200 { key, size }`.
  Server scopes entries by the token's `fork_only` flag (fork/trusted isolation is server-side;
  the runner does nothing for it — regression-tested at the HTTP level).
- `GET /api/v1/projects/:id/cache?keys[]=k1&keys[]=k2` — server tries keys in order (exact,
  then longest-prefix fallback) → `200 { key, size, download_url }` | `404 { error }`.
- `403 { error }` when the token has no active (claimed/running) job in the project — e.g.
  after a cancel; treated as a clean miss by cache steps, never fatal.
- `download_url` is signed (15-min TTL), no auth header on GET, follows ≤ 3 redirects.

## Artifacts

- `POST /api/v1/jobs/:id/artifacts` — multipart `file` + `path` + `destination?` →
  `201 { id, path, destination, size, download_url }`.
  **`destination` is `null` (not omitted) when unset** — the only place a null appears
  where absence would also be legal. [fixture `artifact-created-201.json`]

## Workspaces (runner-level protocol on the cache API)

Reserved namespace, unchanged from the Ruby runner:
`forge-ci-workspace/<workflow_run_id>/manifest.json` (JSON array of roots) and
`forge-ci-workspace/<workflow_run_id>/<sanitized-root>.tgz`. persist uploads each root
tarball then the manifest; attach reads the manifest then extracts each root tarball at `at`.

## Runner-level behavior pinned by fixtures

- Idle backoff 5s→10s→…→60s cap on 422; reset on claim. Once
  `IDLE_SHUTDOWN_AFTER` elapses, the runner requests Outlook only when
  `IDLE_LINGER_MAX > 0`. Positive counts keep claim polling at
  `IDLE_OUTLOOK_INTERVAL` (default 15s), bounded by the extra linger maximum;
  both Outlook and claim requests are deadline-bounded to that cap. Zero
  counts, request errors/404, or reaching the cap shut down at/after base idle.
  A claimed job resets the idle clock. A zero linger maximum preserves
  immediate base-idle shutdown and makes no Outlook request.
- `when` evaluation: `on_success` runs only while no earlier step failed; `on_fail` only
  after a failure; `always` always; unknown values fall back to on_success semantics.
  Non-`run` steps follow on_success semantics.
- Exit codes: step killed for silence (`no_output_timeout`, default 600s) or job deadline
  (default 3600s) → `124`; stopped for cancellation/shutdown → `130`.
- Interruption removes the primary container before the active step returns,
  killing its descendants and detached background steps. All remaining steps,
  including `on_fail` and `always`, are logged as skipped (`job interrupted`)
  because their container is no longer available. Silence/deadline interruption
  fails the job; ordinary command failures still allow `on_fail`/`always` steps.
  Ordinary TERM finishes the active step and reports canceled even if it was the
  final step; requeue shutdown interrupts instead.
  This is Go behavior, not complete timeout parity: Ruby checks deadlines
  while streaming commands and kills the `docker exec` client, leaving
  container-side work until final cleanup. Both support the same timeout
  defaults, but Go's job deadline also bounds setup and transfers.
- Skipped steps report `exit_code: 0` with identical start/finish timestamps.
- Durations parse `30s`/`10m`/`1h`/bare seconds; unparseable → step/config default.
- Secrets redacted from logs: every job, step, and service env value (including
  shadowed values) ≥ `REDACT_MIN_LENGTH` (default 8), plus all `secret_values`,
  checkout tokens, and build-cache passwords regardless of length. Matching is
  longest-first exact substring → `[REDACTED]`, including across streamed
  read boundaries.
- Output bytes that are invalid UTF-8 are replaced with U+FFFD at chunk emission
  (before JSON encoding); valid multi-byte characters are never split across chunks.

## Fixture index (`contract/`)

| File | Pins |
|---|---|
| `claim-full.json` | Full payload: repository+token, docker_build_cache+credentials, secondary_images, mixed steps |
| `claim-classless.json` | Classless token + NULL-class job; minimal executor (image only) |
| `claim-fork.json` | `trusted: false`, executor-env-only environment, repository without `token` |
| `claim-trusted-absent.json` | Older server: no `trusted`/`project_id`/`workflow_run_id`/`docker_build_cache` |
| `claim-upcoming-422.json` | 422 idle body with `upcoming` |
| `claim-unauthorized-401.json` | 401 body |
| `steps-variants.json` | run (background, when: always, no_output_timeout, step env), checkout w/ path, unknown type |
| `executor-nulls.json` | executor with null entrypoint/command/secondary_images; string-valued environment |
| `lifecycle-ok.json` | start/heartbeat/complete/release 200 bodies (incl. heartbeat `canceled` variant) |
| `lifecycle-errors.json` | 409 release exhaustion, 422 IllegalTransition, 403 non-owner, 404 unknown job |
| `log-chunk-ok.json` + `log-chunk-422.json` | Chunk ack; blank-chunk rejection |
| `cache-ok.json` | PUT ack, GET hit, GET 404 miss, GET 403 |
| `artifact-created-201.json` | Artifact body incl. `"destination": null` |
