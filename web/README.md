# ForgeCI Control Plane (components 2–8)

The Rails control plane for ForgeCI, the open-source CircleCI-compatible CI.
It owns projects, pipelines, workflow/job state machines, the pipeline-intake
API (the seam the GitHub App, component 3, calls), and the polling API the
Docker runner (component 5) drives: **claim → start → heartbeat → log chunks →
complete**.

Component 1 is the [`forge-ci`](https://github.com/azmi2409/forge-ci) config-compiler
gem, consumed here as a path gem (`gem "forge-ci", path: ".."`).

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
| `GITHUB_APP_ID` | Numeric GitHub App ID (component 3). |
| `GITHUB_APP_PRIVATE_KEY` | The App's private key, PEM text (may contain newlines). |
| `GITHUB_WEBHOOK_SECRET` | Webhook HMAC secret. **Fail-closed**: the webhook endpoint 401s every request when this is blank. |
| `APP_HOST` | Public base URL of this app, e.g. `https://ci.example.com` — used for commit-status `target_url` links. Optional. |
| `ACTIVE_STORAGE_SERVICE` | `local` (default) or `amazon` — selects the ActiveStorage service in `config/storage.yml`. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Credentials for the `amazon` storage service (S3 or S3-compatible). |
| `AWS_REGION` | Region for the `amazon` service (default `us-east-1`). |
| `AWS_BUCKET` | Bucket name for the `amazon` service (required when `ACTIVE_STORAGE_SERVICE=amazon`). |
| `AWS_ENDPOINT` | Optional endpoint override for S3-compatible stores (MinIO, etc.), e.g. `http://minio:9000`. Omit for real S3. |
| `ARTIFACT_RETENTION_DAYS` | How long artifacts are kept; `PurgeOldArtifactsJob` deletes older ones daily at 03:00 (Solid Queue recurring, `config/recurring.yml`). Default `30`. |
| `FORGE_CI_ADMIN_TOKEN` | Bearer token for context administration (`POST /api/v1/contexts/:id/rotate`). **Fail-closed**: rotation 503s when this is blank. |
| `FORGE_CI_STREAM_TIMEOUT_SECONDS` | How long the SSE log live-tail stays open waiting for output (default `300`). |

### Object storage setup (components 6–7)

Log blobs, artifacts, and cache tarballs live in ActiveStorage, selected by
`ACTIVE_STORAGE_SERVICE`:

- `local` (default): disk storage under `storage/` — fine for dev/test and
  single-node deploys. Signed download URLs are served by the app itself.
- `amazon`: S3-compatible via `aws-sdk-s3`. Set `AWS_BUCKET` plus credentials;
  point `AWS_ENDPOINT` at MinIO (or any S3-compatible store) for self-hosted
  setups. Signed URLs come straight from the bucket (15-minute TTL), so the
  app never proxies file bytes.

Run `bin/rails db:migrate` after pulling — the ActiveStorage tables
(`active_storage_blobs`, `active_storage_attachments`,
`active_storage_variant_records`) ship in
`db/migrate/20261015130000_create_active_storage_tables.rb`.

**Blob rebuild cost (known):** each log-chunk POST rewrites the whole blob
from the ordered rows (O(n) per chunk). Fine for typical CI logs; the
documented future optimization is delta-append instead of full rebuild.

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
  "workflow_run_id": 1,
  "repository": { "url": "https://github.com/acme/demo.git",       // additive & nil-safe: omitted entirely when
                  "sha": "abc123def456", "branch": "main" } }       // neither the GitHub repo nor project.repo_url is known
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
Only the owning token (`403` otherwise). Chunks are appended to an
ActiveStorage blob **in seq order**; the `LogChunk` rows are kept as a
write-ahead ingestion buffer (idempotent upserts) and purged once the job
reaches a terminal state, at which point the blob becomes the durable log
store. Decision: the model stays (as metadata/buffer), the blob is the
source of truth for reads.

`GET /api/v1/jobs/:id/logs` → `200 { job_id, chunks: [{ seq, chunk }] }`
ordered by `seq`. Served from buffered rows while the job is live, from the
blob once it is terminal.

`GET /api/v1/jobs/:id/logs/stream` — `text/event-stream` live tail. Sends
existing chunks as `chunk` events, then holds the connection open (long
poll, server-side 5-minute default — see `FORGE_CI_STREAM_TIMEOUT_SECONDS`)
emitting new chunks as they arrive, and closes with a `done` event once the
job is terminal. Auth is dual: the owning runner's Bearer token **or** the
UI's HTTP basic credentials (browsers can't set `Authorization: Bearer` on
`EventSource`). The job show page uses this with plain polling as fallback.
Unauthenticated → `401`.

### Artifacts — `Authorization: Bearer <raw-runner-token>` (upload) / Bearer or UI basic (download)

`POST /api/v1/jobs/:id/artifacts` — multipart form: `file` (required), `path`
(defaults to the filename), `destination` (optional prefix shown in the UI).
Only the owning token may upload. Response `201`:

```jsonc
{ "id": 7, "path": "coverage/index.html", "destination": "reports",
  "size": 48210,
  "download_url": "https://…signed…?…" }   // 15-minute TTL — do NOT store it
```

`GET /api/v1/artifacts/:id/download` — `302` redirect to a **fresh** signed
blob URL (15-minute TTL). The blob key itself is never a permanent address.
Old artifacts are purged by `PurgeOldArtifactsJob` after
`ARTIFACT_RETENTION_DAYS` (default 30).

### Cache — `Authorization: Bearer <raw-runner-token>`

The token must own a `claimed`/`running` job in the project (`403`
otherwise) — cache access is tied to active work, not to any token.

`PUT /api/v1/projects/:project_id/cache` — multipart form: `key` (required),
`file` (the tarball, required). Upserts on `(project_id, key)` — re-saving a
key replaces the blob. Response `200 { key, size }`.

`GET /api/v1/projects/:project_id/cache?keys[]=k1&keys[]=k2` — tries the keys
in order with CircleCI `restore_cache` semantics: exact match wins, otherwise
the most recent entry whose stored key **starts with** the requested key
(longest-prefix fallback). `404 { error: "no matching cache entry" }` when
nothing matches. Hit response `200`:

```jsonc
{ "key": "bundle-v1-abc123", "size": 89123456, "download_url": "https://…signed…?…" }
```

### Contexts (secrets) — `Authorization: Bearer <FORGE_CI_ADMIN_TOKEN>`

Runner tokens can **never** read or rewrite secrets; rotation uses a separate
admin token. Fail-closed: every request `503`s when
`FORGE_CI_ADMIN_TOKEN` is blank.

`POST /api/v1/contexts/:id/rotate` — `{ "payload": { "KEY": "new-value", … } }`
replaces the encrypted payload wholesale (Rails `encrypts` at rest stays as
is). The response carries **key names only** — values are never echoed back:

```jsonc
// 200
{ "id": 3, "name": "deploy", "keys": ["AWS_KEY", "AWS_SECRET"], "updated_at": "2026-10-15T…" }
// 401 bad token · 404 unknown context · 422 empty payload or blank key · 503 admin token not configured
```

## GitHub App setup (component 3)

Pushes and pull requests become forge-ci pipelines automatically once a
GitHub App is installed on the account. Flow:

`push` / `pull_request` webhook → HMAC-verified → `Github::SyncPipelineJob`
→ fetch `.circleci/config.yml` at the event SHA → compile with the forge-ci
gem → `PipelineIntake` (the same seam as the REST API) → `pending` commit
status → runners claim jobs → terminal status (`success`/`failure`) posted
back via `Pipeline#after_update_commit`.

### 1. Register the App on github.com (manual)

GitHub → Settings → Developer settings → GitHub Apps → New GitHub App:

- **Webhook URL**: `https://<your-host>/api/v1/github/webhooks` (the app must
  be reachable over public HTTPS — this step waits until deployment)
- **Webhook secret**: generate one, set it as `GITHUB_WEBHOOK_SECRET`
- **Permissions**: Contents — Read only; Commit statuses — Read and write;
  Pull requests — Read only; Metadata — Read only (mandatory)
- **Subscribe to events**: `push`, `pull_request`, `installation`

Then install the App on the account/org and note the **App ID**; generate a
**private key** (PEM) and set `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY`.

### 2. How repos map to projects

On the first push from a repo the app has never seen, the sync job
**auto-creates** a `Project` named after the repo's `owner/name` plus the
`GithubRepository` mapping. Install/uninstall events keep the
`GithubInstallation` rows in sync.

### 3. Fork-PR secret gating (security)

Pull requests from forks are detected (`head.repo != base.repo`) and marked
`Pipeline#forked = true`. **Forked pipelines never receive contexts** —
`context_names: []` is forced at intake regardless of the project's
configured contexts, so secrets can't leak into untrusted fork code.
Non-fork pipelines get the project's default contexts (all of them, in v1).

## Secrets threat model (component 8)

What's protected:

- **At rest**: Context payloads are encrypted with Rails `encrypts`
  (`ACTIVE_RECORD_ENCRYPTION_*` keys; production must set real ones — dev/test
  fall back to loud, insecure dev keys).
- **In transit / in API responses**: raw Context records are never serialized.
  The claim payload exposes only the *merged* `environment`; the rotate
  endpoint returns key *names* only; the web UI renders masked values
  (`••••••`). Tests assert values appear nowhere outside the merged env.
- **Administration**: rotation (`POST /api/v1/contexts/:id/rotate`) requires a
  dedicated `FORGE_CI_ADMIN_TOKEN`, never a runner token, and is fail-closed
  (503 when unconfigured).
- **Fork PRs**: never receive contexts at all (see above).

What's still manual / runner-side:

- **Secret redaction in logs is runner-side.** If a job `echo`s a secret, the
  control plane stores and streams it verbatim — the Docker runner is
  responsible for masking known secret values before POSTing log chunks.
- **No per-branch context scoping** — a context is all-or-nothing per project
  (v1 gives every non-fork pipeline all of the project's default contexts).
- **No audit log** of who rotated what, when.

### 4. Compile errors are not silent

If `.circleci/config.yml` fails to compile, the push still creates a
**failed** pipeline and posts a `failure` commit status carrying the first
error lines. A repo with no config file at the SHA is skipped quietly
(nothing to build).

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
   Chunks land in an ActiveStorage blob in seq order. **Mask secret values
   before sending** — the control plane stores and streams log text verbatim
   (secret redaction is runner-side, see "Secrets threat model").
6. Upload artifacts: `POST /api/v1/jobs/:id/artifacts` (multipart `file` +
   `path`/`destination`) → `201` with a 15-minute signed `download_url`;
   consumers should use `GET /api/v1/artifacts/:id/download` for a fresh URL.
7. Cache: `PUT /api/v1/projects/:project_id/cache` with multipart `key` +
   `file` (tarball) to save; `GET …/cache?keys[]=k1&keys[]=k2` to restore
   (exact match, then longest-prefix fallback, `404` on miss).
8. Finish: `POST …/complete` with `status` and per-step `step_results`
   (`name` must match the step names from the claim payload).
9. Never invent job IDs, never touch another token's jobs (`403`), never
   expect raw context values anywhere except the claim payload's merged
   `environment`.

The claim payload also carries `repository: { url, sha, branch }` (resolved
from the pipeline's GitHub repo, else the project's `repo_url`, omitted when
neither is known) — use it for `checkout` instead of requiring a
`CHECKOUT_REPO_URL` env var. The key is additive, so older runners ignore it
safely.

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
dependents. Fixed additively in the repo root (commit `ca9f633`):

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
- `LogChunk` — job_run, seq, chunk (unique `(job_run_id, seq)` for idempotent upserts).
  Write-ahead ingestion buffer: rows are purged when the job goes terminal and
  the ActiveStorage **log blob** (`JobRun#log_blob`) becomes the durable store.
- `Artifact` — job_run, path, destination, size, storage_key; file in
  ActiveStorage (`Artifact#file`). Purged after `ARTIFACT_RETENTION_DAYS`.
- `CacheEntry` — project, key, size, storage_key; tarball in ActiveStorage
  (`CacheEntry#file`). Upsert on `(project_id, key)`; lookup is exact-match
  then longest-prefix (`CacheEntry.lookup`).
- `Context` — project, name, payload encrypted via `encrypts` (values never
  logged, rendered, or returned raw)
- `RunnerToken` — name, token_digest (SHA256 hex **only**), resource_class

## Not yet (deferred)

- GitHub App auth on the raw intake endpoint (currently unauthenticated; the
  GitHub flow goes through the HMAC-verified webhook instead)
- Real UI auth (login, RBAC) — v1 is HTTP basic auth via env vars
- Pipeline cancel API
- Per-branch context scoping; secret redaction stays runner-side (see
  "Secrets threat model"); rotation audit log
- Log blob delta-append (currently each chunk POST rewrites the whole blob
  from the ordered rows — O(n) per chunk)
- `FOR UPDATE SKIP LOCKED` semantics on non-Postgres adapters (SQLite dev fallback uses a plain transactional claim)
- Solid Queue tables are not auto-installed in dev — run `bin/rails solid_queue:install` before `bin/jobs`
- GitHub App registration itself (manual; waits on a public HTTPS URL for the control plane)

## License

MIT — same as the `forge-ci` gem.
