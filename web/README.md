# ForgeCI Control Plane (components 2–8)

The Rails control plane for ForgeCI, the open-source CircleCI-compatible CI.
It owns projects, pipelines, workflow/job state machines, the pipeline-intake
API (the seam the GitHub App, component 3, calls), and the polling API the
Docker runner (component 5) drives: **claim → start → heartbeat → log chunks →
complete**.

Component 1 is the [`forge-ci`](https://github.com/azmi2409/forge-ci) config-compiler
gem, consumed here as a path gem (`gem "forge-ci", path: ".."`).

> **Docs:** [architecture](../docs/architecture.md) · [API](../docs/api.md) · [configuration](../docs/configuration.md) · [troubleshooting](../docs/troubleshooting.md) · [contributing](../CONTRIBUTING.md)

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

Full reference: [docs/configuration.md](../docs/configuration.md).
Key production secrets: `DATABASE_URL`, `RAILS_MASTER_KEY`,
`FORGE_CI_UI_USER`/`FORGE_CI_UI_PASSWORD`, `ACTIVE_RECORD_ENCRYPTION_*`,
`GITHUB_*` (app), `FORGE_CI_ADMIN_TOKEN`, S3 credentials — see
[DEPLOY.md](../DEPLOY.md).

### Object storage setup (components 6–7)

Log blobs, artifacts, and cache tarballs live in ActiveStorage, selected by
`ACTIVE_STORAGE_SERVICE`:

- `local` (default): disk storage under `storage/` — fine for dev/test and
  single-node deploys. Signed download URLs are served by the app itself.
- `amazon`: S3-compatible via `aws-sdk-s3`. Set `AWS_S3_BUCKET` plus credentials;
  point `AWS_S3_ENDPOINT` at MinIO (or any S3-compatible store) for self-hosted
  setups, with `AWS_S3_FORCE_PATH_STYLE=true`
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

Server-rendered ERB, no CSS/JS framework (small inline styles). Cookie-session login (`/login`; see "Authentication")
(see above; real login/RBAC is deferred).

- `/` — projects index + recent pipelines
- `/projects/:project_id/pipelines/:id` — pipeline detail: each workflow's
  jobs in topological order with `requires` edges, status badges, claim info
- `/job_runs/:id` — job detail: executor, steps with exit codes, and a log
  viewer rendered from stored log chunks

Status colors: pending gray · queued blue · claimed purple · running amber ·
success green · failed red · canceled dark gray.

## API reference (v1)

Moved to [docs/api.md](../docs/api.md) — full v1 reference: pipeline
intake, runner claim/lifecycle, logs, artifacts, cache, contexts,
and the runner contract checklist.

## GitHub App setup (component 3)

Pushes and pull requests become forge-ci pipelines automatically once a
GitHub App is installed on the account. Flow:

`push` / `pull_request` webhook → HMAC-verified → `Github::SyncPipelineJob`
→ fetch `.circleci/config.yml` at the event SHA → compile with the forge-ci
gem → `PipelineIntake` (the same seam as the REST API) → `pending` commit
status → runners claim jobs → terminal status (`success`/`failure`) posted
back via `Pipeline#after_update_commit`.

### 1. Register the App

The easy way: **Settings → Connect GitHub** in the web UI registers the App
through GitHub's manifest flow and stores its credentials (encrypted) in the
`github_app_credentials` table. To register it by hand instead (the
`GITHUB_*` environment variables then take precedence):

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

## Runner contract

See the checklist in [docs/api.md](../docs/api.md#runner-contract-checklist-for-runner-implementations).

## Background: reclaiming stale jobs

`JobRun.reclaim_stale!` returns `claimed`/`running` jobs with
`heartbeat_at` older than `JobRun::STALE_HEARTBEAT_AFTER` (**120s**) to
`queued` (clearing `claimed_by/at`). Thresholds are constants, documented and
tunable in one place (`app/models/job_run.rb`).

- Solid Queue recurring task: `config/recurring.yml` runs
  `ReclaimStaleJobsJob` every `JobRun::RECLAIM_INTERVAL` (**60s**).
  docker-compose.yml runs the worker as its own `worker` container
  (`bin/jobs`); a lone `docker run` of the image runs it inside Puma
  (`SOLID_QUEUE_IN_PUMA=1`, the image default). In development run `bin/jobs`.
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
  claimed_by/at, heartbeat_at, releases (times a shutting-down runner put it
  back in the queue, at most `JobRun::MAX_RELEASES`)
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

## Authentication

The UI uses a cookie session (`/login`). Users live in the `users` table
(salted PBKDF2-HMAC-SHA256, no extra gem). Roles: **admin** (everything,
including `/users`) and **member** (view + cancel pipelines).

- First run: while no users exist, the first login with
  `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` creates an admin. Or:
  `FORGE_USERNAME=alice FORGE_PASSWORD='long passphrase' bin/rails forge_ci:create_user`
  (also resets a password; `FORGE_ROLE=member` for non-admins).
- 5 consecutive bad passwords lock the account for 15 minutes; passwords need
  10+ characters; sessions expire after 12h idle / 7 days absolute; changing a
  password or "Sign out everywhere else" invalidates other sessions.
- The log stream/artifact download endpoints accept the same session cookie
  (or the owning runner's bearer token). Runner and admin APIs are unchanged.
- Behind HTTPS set `FORCE_SSL=true` for a Secure cookie and HSTS.

## Not yet (deferred)

- SSO/OIDC, 2FA, per-project permissions
- Per-branch context scoping; secret redaction stays runner-side (see
  "Secrets threat model"); rotation audit log
- Log blob delta-append (currently each chunk POST rewrites the whole blob
  from the ordered rows — O(n) per chunk)
- `FOR UPDATE SKIP LOCKED` semantics on non-Postgres adapters (SQLite dev fallback uses a plain transactional claim)
- Solid Queue tables are not auto-installed in dev — run `bin/rails solid_queue:install` before `bin/jobs`
- GitHub App registration itself (manual; waits on a public HTTPS URL for the control plane)

## License

MIT — same as the `forge-ci` gem.
