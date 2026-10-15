# API reference (v1)

All request/response bodies are JSON unless noted (artifact/cache uploads are
multipart). Base path: `/api/v1`.

## Pipeline intake

`POST /api/v1/projects/:project_id/pipelines` — unauthenticated in v1 (the
GitHub flow goes through the HMAC-verified webhook instead).

```jsonc
{
  "sha": "abc123def456",
  "branch": "main",
  "ir": { /* compiler IR: { version, workflows: [{ name, jobs: [{ name, requires: [...], executor: {...}, working_directory, steps: [...] }] }], meta } */ },
  "contexts": ["deploy"]            // optional: named Contexts for the project
}
```

- `ir` may use string keys (normal HTTP/JSON) or symbol keys (direct Ruby).
- Validates the IR (workflows → jobs → name/executor/steps); `422` with
  `details` on violation. Unknown context name → `404`. Unknown project → `404`.
- Creates the Pipeline (`running`), one WorkflowRun per workflow (`running`),
  one JobRun per job — `queued` when `requires` is empty, else `pending` —
  plus one StepRun per IR step (`pending`). Each job stores its pruned
  `requires` list, the denormalized `resource_class`, and the merged context
  environment.
- Response `201`:

```jsonc
{ "id": 1, "project_id": 1, "sha": "abc123def456", "branch": "main", "status": "running",
  "workflows": [{ "id": 1, "name": "build-test-deploy", "status": "running",
    "jobs": [{ "id": 1, "name": "build", "status": "queued", "requires": [] },
             { "id": 2, "name": "test", "status": "pending", "requires": ["build"] }] }] }
```

## Runner API — `Authorization: Bearer <raw-runner-token>` on every call

Tokens are created with `RunnerToken.generate!(name:, resource_class:)` →
`[record, raw_token]`; only the SHA256 hex digest is stored, compared with
`secure_compare`. Missing/wrong token → `401`. Acting on a job owned by
another token → `403`.

### Claim

`POST /api/v1/runner/jobs/claim` — `{ "resource_class": "medium" }` (optional)

Atomically claims the oldest `queued` job the token may run and returns the
full job payload (`200`), or `422` when nothing is claimable. Matching: job
`executor.resource_class` == token `resource_class`, **or either side is
NULL** (NULL matches anything); the job's project must have a free
`max_concurrency` slot (counted across `claimed` + `running` jobs).

On Postgres the candidate scan takes `FOR UPDATE SKIP LOCKED` inside a
transaction (concurrent runners resolve the race atomically); other adapters
use a plain ordered first-row claim inside the transaction. The claim sets
`claimed` + `claimed_by` (token name) + `claimed_at` + `heartbeat_at`.

```jsonc
// 200 response
{ "id": 1, "name": "build", "working_directory": "~/project",
  "executor": { "type": "docker", "image": "cimg/ruby:3.2", "resource_class": "medium",
                "environment": { "RAILS_ENV": "test" } },
  "steps": [{ "type": "checkout" }, { "type": "run", "name": "Bundle", "command": "bundle install" }],
  "environment": { "RAILS_ENV": "test", "DEPLOY_KEY": "s3cr3t" },  // executor env merged with context payloads; contexts win
  "pipeline": { "sha": "abc123def456", "branch": "main" },
  "workflow_run_id": 1,
  "project_id": 1,
  "repository": { "url": "https://github.com/acme/demo.git",       // additive & nil-safe: omitted entirely when
                  "sha": "abc123def456", "branch": "main" } }       // neither the GitHub repo nor project.repo_url is known
// Raw Context records are NEVER returned.
```

### Lifecycle

- `POST /api/v1/runner/jobs/:id/heartbeat` → `200 { id, status, heartbeat_at }`.
  Only the claiming token may heartbeat its own jobs (`403` otherwise).
- `POST /api/v1/runner/jobs/:id/start` — `claimed → running` (`200`), called
  when the container actually starts so the two states stay distinguishable.
  `422` on illegal transition.
- `POST /api/v1/runner/jobs/:id/complete`

```jsonc
{ "status": "success",                                   // "success" | "failed" | "canceled"
  "step_results": [{ "name": "Bundle", "exit_code": 0,
                      "started_at": "2026-10-15T09:00:00Z", "finished_at": "2026-10-15T09:01:12Z" }] }
```

Terminal state (`200 { id, status }`); `422` on illegal transition or
non-terminal status. Updates matching StepRuns by name (exit code,
timestamps, derived status). On `success`: dependents in the same workflow
whose `requires` are now **all** successful move `pending → queued`. On
`failed`/`canceled`: dependents stay `pending`. Workflow status recomputes
(`failed` if any job failed → `canceled` → `running` while anything is in
flight → `success`) and rolls up to the pipeline.

### Logs

- `POST /api/v1/jobs/:id/log_chunks` — `{ "seq": 3, "chunk": "…log text…" }`.
  Upsert on `(job_run_id, seq)` — safe to retry; `200 { job_id, seq }`. Only
  the owning token (`403` otherwise). Chunks are appended to an ActiveStorage
  blob **in seq order**; the `LogChunk` rows are a write-ahead ingestion
  buffer, purged once the job reaches a terminal state.
- `GET /api/v1/jobs/:id/logs` → `200 { job_id, chunks: [{ seq, chunk }] }`
  ordered by `seq`. Served from buffered rows while the job is live, from the
  blob once terminal.
- `GET /api/v1/jobs/:id/logs/stream` — `text/event-stream` live tail. Sends
  existing chunks as `chunk` events, holds the connection open emitting new
  chunks, closes with `done` once the job is terminal. Auth is dual: the
  owning runner's Bearer token **or** the UI's HTTP basic credentials
  (browsers can't set `Authorization: Bearer` on `EventSource`).
  Unauthenticated → `401`.

**Mask secret values before sending** — the control plane stores and streams
log text verbatim; redaction is the runner's job.

## Artifacts — Bearer (upload) / Bearer or UI basic (download)

- `POST /api/v1/jobs/:id/artifacts` — multipart: `file` (required), `path`
  (defaults to filename), `destination` (optional UI prefix). Only the owning
  token may upload. `201`:

```jsonc
{ "id": 7, "path": "coverage/index.html", "destination": "reports",
  "size": 48210,
  "download_url": "https://…signed…?…" }   // 15-minute TTL — do NOT store it
```

- `GET /api/v1/artifacts/:id/download` — `302` to a **fresh** signed blob URL
  (15-minute TTL). Old artifacts are purged after `ARTIFACT_RETENTION_DAYS`.

## Cache — `Authorization: Bearer <raw-runner-token>`

The token must own a `claimed`/`running` job in the project (`403`
otherwise) — cache access is tied to active work, not to any token.

- `PUT /api/v1/projects/:project_id/cache` — multipart: `key` (required),
  `file` (the tarball, required). Upserts on `(project_id, key)`.
  `200 { key, size }`.
- `GET /api/v1/projects/:project_id/cache?keys[]=k1&keys[]=k2` — tries keys
  in order with CircleCI `restore_cache` semantics: exact match wins,
  otherwise the most recent entry whose stored key **starts with** the
  requested key (longest-prefix fallback). `404 { error: "no matching cache
  entry" }` on miss; hit → `200 { key, size, download_url }`.

## Contexts (secrets) — `Authorization: Bearer <FORGE_CI_ADMIN_TOKEN>`

Runner tokens can **never** read or rewrite secrets. Fail-closed: every
request `503`s when `FORGE_CI_ADMIN_TOKEN` is blank.

`POST /api/v1/contexts/:id/rotate` — `{ "payload": { "KEY": "new-value", … } }`
replaces the encrypted payload wholesale. The response carries **key names
only** — values are never echoed back:

```jsonc
// 200
{ "id": 3, "name": "deploy", "keys": ["AWS_KEY", "AWS_SECRET"], "updated_at": "2026-10-15T…" }
// 401 bad token · 404 unknown context · 422 empty payload or blank key · 503 admin token not configured
```

## Runner contract (checklist for runner implementations)

1. Generate a token: `RunnerToken.generate!(name: "worker-1", resource_class: "medium")`
   and store the raw token on the runner host.
2. Poll `POST /api/v1/runner/jobs/claim` every **5–10s** when idle
   (`{ "resource_class": "medium" }` optional).
3. On `200`: `POST …/start` when the container starts.
4. `POST …/heartbeat` every **~30s** while running. Miss the **120s**
   staleness threshold and the reclaimer returns the job to `queued`.
5. Stream logs: `POST /api/v1/jobs/:id/log_chunks` with monotonically
   increasing `seq` (~64KB chunks); retries are idempotent. **Mask secrets
   before sending.**
6. Artifacts: `POST /api/v1/jobs/:id/artifacts` (multipart `file` +
   `path`/`destination`) → `201`; use `GET /api/v1/artifacts/:id/download`
   for fresh URLs.
7. Cache: `PUT /api/v1/projects/:project_id/cache` (multipart `key` +
   `file`); `GET …/cache?keys[]=k1&keys[]=k2`.
8. Finish: `POST …/complete` with `status` + `step_results` (`name` must
   match the claim payload's step names).
9. Never invent job IDs, never touch another token's jobs (`403`), never
   expect raw context values outside the claim payload's merged `environment`.
