# API reference (v1)

All request/response bodies are JSON unless noted (artifact/cache uploads are
multipart). Base path: `/api/v1`.

## Authentication

The JSON API accepts two kinds of Bearer credentials:

- the shared **admin token** (`FORGE_CI_ADMIN_TOKEN`, shown on the Settings
  page) — full access, for scripts and CI;
- a **personal OAuth token** from `forge-ci login` — the request acts as the
  signed-in web-UI user. Members can view and cancel; admins can do
  everything (intake, project creation, contexts, queue). Tokens are
  authorization-code + PKCE, issued by the server's Doorkeeper endpoints
  (`/oauth/authorize`, `/oauth/token`, `/oauth/revoke`), expire after 24h
  and are refreshed automatically by the CLI.

`GET /api/v1/me` reports who the presented token acts as
(`{ username, role }` or `{ admin_token: true, role: "admin" }`) — `forge-ci
login` verifies with it. Anything else unauthenticated → `401`.

`forge-ci logout` revokes the stored refresh token (or access token when no
refresh token exists), including sessions whose access token has expired.
After a refreshed access token is first used successfully, its previous
refresh token can no longer be reused. If server revocation fails, logout
warns and still removes local credentials; server-side access may remain valid.

The CLI validates callback state on both success and OAuth errors and limits
the browser callback wait to five minutes. Credentials are replaced atomically
with mode `0600`; unreadable or malformed credentials files fail explicitly
rather than silently discarding other saved sessions.

## Pipeline intake

`POST /api/v1/projects/:project_id/pipelines` — requires an admin (see
above). The GitHub flow goes through the
HMAC-verified webhook instead. The easiest client is the CLI:
`forge-ci trigger .circleci/config.yml --project NAME --wait`.

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

## Admin API — admin token, or an admin user's OAuth token

The whole table below needs an admin, except project/pipeline **listing** and
pipeline **status/cancel**, which also accept a member's OAuth token.

| Call | Purpose |
|---|---|
| `GET /api/v1/projects` | list projects (`{ projects: [{ id, name, repo_url, default_branch, max_concurrency }] }`) |
| `POST /api/v1/projects` `{ name, repo_url?, default_branch?, max_concurrency? }` | create a project (`201`; `422` on invalid/duplicate name) |
| `POST /api/v1/projects/:id/contexts` `{ name, payload: { KEY: "value" } }` | create a context, or replace the payload of the same-named one. Responds with key names only |
| `POST /api/v1/contexts/:id/rotate` `{ payload: {...} }` | replace a context's secrets |
| `GET /api/v1/pipelines/:id` | pipeline + workflow + job statuses (same shape as the intake response) |
| `GET /api/v1/projects/:project_id/pipelines` | newest-first pipeline summaries: `{ pipelines: [{ id, project_id, sha, branch, status }] }`; optional exact `branch` and `sha` filters, `limit` defaults to 20 (1–100). Invalid filters/limit return `400`; missing project returns `404`. No workflows or secrets in summaries. |
| `GET /api/v1/queue` | queued and in-flight (claimed + running) job counts per resource class, for runner autoscalers: `{ resource_classes: { spot: { queued, running }, any: {...} } }` (`any` = jobs without a class) |
| `POST /api/v1/pipelines/:id/cancel` | cancel every unfinished job. Running jobs are stopped by their runner on its next heartbeat (`status: "canceled"` in the heartbeat reply). Idempotent |

When a job fails, jobs that (transitively) `require` it are canceled instead
of being left pending, and the pipeline/workflow only becomes `failed` once
no job is still in flight.

CLI reads existing automatic or manually triggered runs without triggering work:

```sh
forge-ci pipelines --project owner/repo --branch main --limit 10
forge-ci status 42
forge-ci status 42 --wait --poll 5
forge-ci status 42 --wait --json
```

Both commands use `--url`/`FORGE_CI_URL` and existing token precedence
(`--token`, `FORGE_CI_ADMIN_TOKEN`, saved login with refresh). A successful
one-shot read exits 0 regardless of pipeline state. Watch exits 0 only for
success, otherwise 1; JSON watch prints only the final document. API errors
exit 1, invalid CLI usage exits 2. Listing requires the updated server;
status by ID uses the existing detail endpoint.

## Runner API — `Authorization: Bearer <raw-runner-token>` on every call

Tokens are created with `RunnerToken.generate!(name:, resource_class:, fork_only: false)` →
`[record, raw_token]`; only the SHA256 hex digest is stored, compared with
`secure_compare`. Missing/wrong token → `401`. Acting on a job owned by
another token → `403`. Default tokens claim trusted repository jobs only;
`fork_only: true` tokens claim fork jobs only. The shared runner token is
always trusted-only. Trust cannot be overridden by claim request parameters.

### Idle outlook

`GET /api/v1/runner/outlook` uses runner-token authentication (missing/invalid
credentials return `401`; admin and personal OAuth tokens are not accepted). It
returns only aggregate counts, never project/job data:

```json
{ "queued": 0, "running": 0, "pending": 0 }
```

Counts follow the calling token's trust pool (`trusted` or `fork_only`) and the
resource class it can claim, including classless jobs. A token-pinned class wins;
a classless token may pass `?resource_class=NAME` (omitting it means any class).
`queued` counts eligible queued jobs whose project has a free `max_concurrency`
slot, `running` includes claimed and running jobs, and `pending` includes only
jobs in active pipelines/workflows whose required jobs have not failed or been
canceled. Terminal pipelines/workflows and unreachable pending jobs are excluded.
This is a best-effort hint for bounded idle linger, not a reservation; a new job
can arrive after the count is read.

### Claim

`POST /api/v1/runner/jobs/claim` — `{ "resource_class": "medium" }` (optional)

Atomically claims the oldest `queued` job the token may run and returns the
full job payload (`200`), or `422` when nothing is claimable. Matching: job
`executor.resource_class` == token `resource_class`, **or either side is
NULL** (NULL matches anything); the job's project must have a free
`max_concurrency` slot (counted across `claimed` + `running` jobs).

Trust pools are exclusive, including classless jobs: fork-only tokens never
claim trusted jobs and trusted-only tokens never claim fork jobs. Fork jobs
receive no project variables or context secrets. Provision fork-only runners
on separate disposable hosts, never on deployment infrastructure.
Fork checkout excludes GitHub App credentials and operator repository URLs;
only anonymous GitHub checkout is supported for fork jobs. Cache reads and
writes use separate trusted/fork namespaces, including prefix lookup.

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
                  "sha": "abc123def456", "branch": "main",          // neither the GitHub repo nor project.repo_url is known
                  "token": "ghs_..." } }                            // GitHub App installation token; only for App-backed repos
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

- `POST /api/v1/runner/jobs/:id/release` — `{ "reason": "runner shutting down (SIGTERM)" }`

A runner with `REQUEUE_ON_SHUTDOWN` that is shutting down mid-job hands the
job back: `claimed|running → queued` (`200 { id, status }`), as if never
run (logs, artifacts and step results cleared, no runner), for another
runner to claim. Only the owning token (`403` otherwise). `409 { error }`
once the job has been released `MAX_RELEASES` (2) times; the runner then
completes it as `canceled`. `422` from any other state.

### Logs

- `POST /api/v1/jobs/:id/log_chunks` — `{ "seq": 3, "chunk": "…log text…" }`.
  Upsert on `(job_run_id, seq)` — safe to retry; `200 { job_id, seq }`. Only
  the owning token (`403` otherwise). The `LogChunk` rows hold the log while
  the job runs; when it finishes they're written to an ActiveStorage blob
  **in seq order** and purged.
- `GET /api/v1/jobs/:id/logs[?after=SEQ]` → `200 { job_id, status, complete, chunks: [{ seq, chunk }] }`.
  `after` returns only newer chunks. `complete: true` means the job finished
  and `chunks` is the whole log as one chunk.
- **Action Cable** `JobLogChannel` (`/cable`, signed-in UI session,
  `{ job_id }`): notices `{ event: "chunk", seq }` and
  `{ event: "done", status }`, with no log text. The job page fetches the new
  chunks with `?after=` on each one.
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

Both Ruby (`runner/`, default) and Go (`runner-go/`, opt-in) implement this
contract; switching implementation does not change endpoints or token trust
pools. See [migration](../DEPLOY.md#ruby-to-go-runner-migration) and the
[frozen Go contract](../runner-go/CONTRACT.md). Go interrupted steps remove
the primary container before final reporting; remaining steps are skipped.

### Runner presence

Updated clients send these optional headers on claim/start/heartbeat/complete/release:

- `X-Forge-Runner-ID`: UUID generated once per client process.
- `X-Forge-Runner-Hostname`: hostname, at most 255 characters.
- `X-Forge-Runner-Implementation`: `ruby` or `go`.

Identity is scoped to the authenticated runner token; hostname is display metadata,
not proof of host identity. Supplied invalid metadata returns `400` before claiming
work. Requests without an identity retain the existing job API behavior but do not
register presence. Empty claim responses (`422`) still update last contact.
Settings is admin-only. Presence is offline after 120 seconds without lifecycle
contact; otherwise an active assigned job means busy, and no active job means idle.
Presence does not change job ownership, authorization, or stale-job recovery.

### Job lifecycle

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
   match the claim payload's step names). A runner that is shutting down
   may `POST …/release` instead, if its jobs are safe to retry.
9. Never invent job IDs, never touch another token's jobs (`403`), never
   expect raw context values outside the claim payload's merged `environment`.
