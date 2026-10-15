# ForgeCI Control Plane (component 2)

The Rails control plane for ForgeCI, the open-source CircleCI-compatible CI.
It owns projects, pipelines, workflow/job state machines, the pipeline-intake
API (the seam the GitHub App, component 3, calls), and the polling API the
Docker runner (component 5) drives: **claim → start → heartbeat → log chunks →
complete**.

Component 1 is the [`forge-ci`](https://github.com/azmi2409/forge-ci) config-compiler
gem, consumed here as a path gem (`gem "forge-ci", path: "../forge-ci"`).

## Versions used

- Ruby **3.2.3**, Rails **8.1.4**
- **PostgreSQL is the supported database** (9.5+). The atomic runner-claim
  path uses `SELECT … FOR UPDATE SKIP LOCKED`, which is Postgres-only.
- This VM has **no Postgres server** (no `psql`, and `apt-get install
  postgresql` was blocked), so local dev/test here run on **SQLite** via
  `DATABASE_URL`. The schema, queries, and claim code are all written
  Postgres-first with an explicit adapter guard (`JobRun.postgres?`); on
  non-Postgres adapters the claim falls back to a plain ordered first-row
  claim inside a transaction (documented, and covered by an adapter-aware
  race test). `config/database.yml` is Postgres-ready — point `DATABASE_URL`
  at Postgres (or drop it) on any machine that has a server.

## Setup

```sh
bin/setup                 # bundle install + db:prepare
```

With Postgres (recommended):

```sh
createdb forge_ci_web_development
DATABASE_URL="postgres://user:pass@localhost/forge_ci_web_development" bin/rails db:prepare
bin/rails server
```

Without Postgres (SQLite fallback, e.g. this VM):

```sh
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails db:prepare
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails server
```

Seed a demo project, runner token, context, and a compiled pipeline:

```sh
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails db:seed
# prints the RAW runner token once — save it, it is never stored
```

Run the tests (minitest, all green):

```sh
DATABASE_URL="sqlite3:db/test.sqlite3" bin/rails test
```

### Environment variables

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Overrides `config/database.yml` (Postgres URL or `sqlite3:` path). |
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | HTTP basic auth for the web UI. Dev/test default to `admin` / `password` with a logged warning; production refuses to boot the UI without them. |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encryption key for Context payloads. Generate with `bin/rails db:encryption:init`. |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Same. |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Same. |
| | Dev/test fall back to deterministic **insecure** dev keys (loud warning). Never use those in production. |

## Web UI

Server-rendered ERB, no CSS/JS framework (small inline styles). Basic auth
(see above; real login/RBAC is deferred).

- `/` — projects index + recent pipelines
- `/projects/:project_id/pipelines/:id` — pipeline detail: each workflow's
  jobs in topological order with `requires` edges, status badges, claim info
- `/job_runs/:id` — job detail: executor, steps with exit codes, and a log
  viewer rendered from stored log chunks

Status colors: pending gray · queued blue · claimed purple · running amber ·
success green · failed red · canceled dark gray.

## API reference (v1)

All request/response bodies are JSON.

### Pipeline intake (unauthenticated in v1 — GitHub App auth is deferred)

`POST /api/v1/projects/:project_id/pipelines`

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
  `details` on violation.
- Unknown context name → `404`. Unknown project → `404`.
- Creates the Pipeline (`running`), one WorkflowRun per workflow (`running`),
  one JobRun per job — `queued` when `requires` is empty, else `pending` —
  plus one StepRun per IR step (`pending`). Each job stores its pruned
  `requires` list (emitted by the compiler since the requires seam fix),
  the denormalized `resource_class`, and the merged context environment.
- Response `201`:

```jsonc
{ "id": 1, "project_id": 1, "sha": "abc123def456", "branch": "main", "status": "running",
  "workflows": [{ "id": 1, "name": "build-test-deploy", "status": "running",
    "jobs": [{ "id": 1, "name": "build", "status": "queued", "requires": [] },
             { "id": 2, "name": "test", "status": "pending", "requires": ["build"] }] }] }
```

### Runner API — `Authorization: Bearer <raw-runner-token>` on every call

Tokens are created with `RunnerToken.generate!(name:, resource_class:)` →
`[record, raw_token]`; only the SHA256 hex digest is stored, compared with
`secure_compare`. Missing/wrong token → `401`. Acting on a job owned by
another token → `403`.

`POST /api/v1/runner/jobs/claim` — `{ "resource_class": "medium" }` (optional)

Atomically claims the oldest `queued` job the token may run and returns the
full job payload (`200`), or `422` when nothing is claimable. Matching:

- job `executor.resource_class` == token `resource_class`, **or either side
  is NULL** (NULL matches anything);
- the job's project has a free `max_concurrency` slot (counted across
  `claimed` + `running` jobs).

On Postgres the candidate scan takes `FOR UPDATE SKIP LOCKED` inside a
transaction, so concurrent runners resolve the race atomically (the loser sees
no claimable row). Other adapters use a plain ordered first-row claim inside
the transaction. The claim sets `claimed` + `claimed_by` (token name) +
`claimed_at` + `heartbeat_at`.

```jsonc
// 200 response
{ "id": 1, "name": "build", "working_directory": "~/project",
  "executor": { "type": "docker", "image": "cimg/ruby:3.2", "resource_class": "medium",
                "environment": { "RAILS_ENV": "test" }, /* … */ },
  "steps": [{ "type": "checkout" }, { "type": "run", "name": "Bundle", "command": "bundle install" }],
  "environment": { "RAILS_ENV": "test", "DEPLOY_KEY": "s3cr3t" },  // executor env merged with context payloads; contexts win
  "pipeline": { "sha": "abc123def456", "branch": "main" },
  "workflow_run_id": 1 }
// Raw Context records are NEVER returned.
```

`POST /api/v1/runner/jobs/:id/heartbeat` → `200 { id, status, heartbeat_at }`.
Only the claiming token may heartbeat its own jobs (`403` otherwise).

`POST /api/v1/runner/jobs/:id/start` — `claimed → running` (`200`), called
when the container actually starts so the two states stay distinguishable.
`422` on illegal transition.

`POST /api/v1/runner/jobs/:id/complete`

```jsonc
{ "status": "success",                                   // "success" | "failed" | "canceled"
  "step_results": [{ "name": "Bundle", "exit_code": 0,
                      "started_at": "2026-10-15T09:00:00Z", "finished_at": "2026-10-15T09:01:12Z" }] }
```

- Terminal state (`200 { id, status }`); `422` on illegal transition or
  non-terminal status.
- Updates matching StepRuns by name (exit code, timestamps, derived status).
- On `success`: dependent jobs in the same workflow whose `requires` are now
  **all** successful move `pending → queued`. On `failed`/`canceled`:
  dependents stay `pending`.
- Recomputes workflow status (`failed` if any job failed → `canceled` →
  `running` while anything is in flight → `success`) and rolls up to the
  pipeline.

`POST /api/v1/jobs/:id/log_chunks` — `{ "seq": 3, "chunk": "…log text…" }`.
Upsert on `(job_run_id, seq)` — safe to retry; `200 { job_id, seq }`.
Only the owning token (`403` otherwise).

`GET /api/v1/jobs/:id/logs` → `200 { job_id, chunks: [{ seq, chunk }] }`
ordered by `seq`. Simple polling is the v1 live-tail story.

## Runner contract (for component 5, the Docker runner)

1. Generate a token: `RunnerToken.generate!(name: "worker-1", resource_class: "medium")`
   (console or a future admin UI) and store the raw token on the runner host.
2. Poll `POST /api/v1/runner/jobs/claim` every **5–10s** when idle
   (`{ "resource_class": "medium" }` optional — omit it and the server matches
   on the token's class).
3. On `200`: `POST …/start` when the container starts.
4. `POST …/heartbeat` every **~30s** while the job runs. Miss the
   **120s** staleness threshold (`JobRun::STALE_HEARTBEAT_AFTER`) and the
   reclaimer puts the job back to `queued` for another runner.
5. Stream logs: `POST /api/v1/jobs/:id/log_chunks` with monotonically
   increasing `seq` (chunk size ~64KB recommended); retries are idempotent.
6. Finish: `POST …/complete` with `status` and per-step `step_results`
   (`name` must match the step names from the claim payload).
7. Never invent job IDs, never touch another token's jobs (`403`), never
   expect raw context values anywhere except the claim payload's merged
   `environment`.

## Background: reclaiming stale jobs

`JobRun.reclaim_stale!` returns `claimed`/`running` jobs with
`heartbeat_at` older than `JobRun::STALE_HEARTBEAT_AFTER` (**120s**) to
`queued` (clearing `claimed_by/at`). Thresholds are constants, documented and
tunable in one place (`app/models/job_run.rb`).

- Solid Queue recurring task: `config/recurring.yml` runs
  `ReclaimStaleJobsJob` every `JobRun::RECLAIM_INTERVAL` (**60s**).
  Run the worker with `bin/jobs` (after `bin/rails solid_queue:install` if the
  queue tables aren't set up yet).
- Cron alternative: `bin/rails forge_ci:reclaim` every minute.

## The requires seam fix (component 1.1)

The compiler resolved `requires` edges and topologically sorted jobs but did
**not** emit the edges in the IR — the control plane needs them to unblock
dependents. Fixed additively in `../forge-ci` (commit `ca9f633`):

- `compiler.rb` step 5 threads each job's pruned dependency list
  (`pruned[inst]`) through `build_job_ir` into `IR.job`;
- `IR.job(name, job_def, requires = [])` now emits `requires: [...]`
  (array of job-name strings, `[]` when none);
- new test asserts `requires` survive compilation for the
  build→test→deploy fixture (`rake test`: 49 runs, 145 assertions, green).

## Data model

- `Project` — name, repo_url, default_branch, max_concurrency (default 4)
- `Pipeline` — project, sha, branch, status (`pending/running/success/failed/canceled`)
- `WorkflowRun` — pipeline, name, status (same enum)
- `JobRun` — workflow_run, name, executor (JSON), steps (JSON), working_directory,
  requires (string array), resource_class (denormalized for claim queries),
  context_environment (merged JSON), concurrency_key (`project_id/workflow/job`),
  status (`pending → queued → claimed → running → success/failed/canceled`,
  guarded transitions on the model — illegal ones raise
  `JobRun::IllegalTransition`; no state-machine gem),
  claimed_by/at, heartbeat_at
- `StepRun` — job_run, name, status, exit_code, started_at, finished_at
- `LogChunk` — job_run, seq, chunk (unique `(job_run_id, seq)` for idempotent upserts)
- `Artifact` — job_run, path, destination, size, storage_key (record only in v1)
- `CacheEntry` — project, key, storage_key, size (record only in v1)
- `Context` — project, name, payload encrypted via `encrypts` (values never
  logged, rendered, or returned raw)
- `RunnerToken` — name, token_digest (SHA256 hex **only**), resource_class

## Not yet (deferred)

- GitHub webhooks / GitHub App authentication on the intake endpoint (currently unauthenticated)
- Real UI auth (login, RBAC) — v1 is HTTP basic auth via env vars
- SSE/ActionCable live tail — v1 is log-chunk polling
- Artifact/cache upload/download on object storage (models exist; no storage backend or API yet)
- Pipeline cancel API
- Context secrets rotation; per-branch context scoping
- `FOR UPDATE SKIP LOCKED` semantics on non-Postgres adapters (SQLite dev fallback uses a plain transactional claim)
- Solid Queue tables are not auto-installed in dev — run `bin/rails solid_queue:install` before `bin/jobs`

## License

MIT — same as the `forge-ci` gem.
