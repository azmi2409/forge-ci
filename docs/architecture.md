# Architecture

forge-ci is a **control-plane / execution-plane** CI system. The control plane
(Rails) owns all state; runners are stateless daemons that poll for work. This
is the same split CircleCI itself uses: server-side config compilation, jobs
claimed by polling runners.

```
.circleci/config.yml
        │
        ▼ (push / PR webhook, or POST /api/v1/.../pipelines)
┌───────────────────┐
│  Config compiler  │  pure function: YAML → validated IR
│  (forge-ci gem)   │  parse → expand → interpolate → conditionals → DAG → IR
└────────┬──────────┘
         │ IR (JSON)
         ▼
┌───────────────────┐
│  Control plane    │  projects, pipelines, workflow/job state machines
│  (Rails 8)        │  claim API, log/cache/artifact APIs, GitHub App,
└────────┬──────────┘  contexts (encrypted), web UI
         │ claim payload (JSON)
         ▼
┌───────────────────┐
│  Runner daemon    │  poll → claim → docker run → step exec → stream logs
│  (Ruby or Go)     │  → upload artifacts/cache → complete (Docker CLI)
└───────────────────┘
```

## The compiler (component 1)

`ForgeCI::Compiler.compile(yaml, pipeline_params:)` is a **pure function**:
YAML text in, `[ir, errors]` out. No I/O, no network, no Docker. Stages:

1. **Parse** — Psych with line numbers (every error carries its location).
2. **Expand** — reusable `commands:` and `executors:` are inlined with their
   own parameter scope; job-level keys win over executor keys.
3. **Interpolate** — `<< parameters.x >>`, `<< pipeline.git.branch >>`,
   `<< pipeline.number >>` resolve; `<< matrix.x >>` resolves per desugared job.
4. **Conditionals** — `when:`/`unless:` steps are evaluated at compile time.
5. **Workflow DAG** — `requires` edges are validated, cycles detected,
   jobs emitted in topological order. `matrix:` is desugared to `job-0`,
   `job-1`, … (the alias stays usable in `requires`).

The IR is JSON-serializable and is the **only** thing the control plane
accepts — the raw YAML never leaves the intake boundary.

## The control plane (components 2, 3, 4, 6, 7, 8)

### Data model

- **Project** — a repo: `repo_url`, `default_branch`, `max_concurrency`.
- **Pipeline** — one push/PR: `sha`, `branch`, `status`
  (`pending → running → success | failed | canceled`).
- **WorkflowRun** — one workflow in a pipeline; same status enum.
- **JobRun** — one job: `executor` + `steps` (JSON from the IR), `requires`
  (string array), `resource_class`, merged `context_environment`,
  `status` (`pending → queued → claimed → running → success | failed | canceled`).
  Transitions are guarded on the model — illegal ones raise
  `JobRun::IllegalTransition`. No state-machine gem.
- **StepRun** — per-step result: `exit_code`, timestamps, derived status.
- **LogChunk** — `(job_run_id, seq)` write-ahead ingestion buffer for log
  chunks; purged when the job goes terminal, at which point the ActiveStorage
  **log blob** becomes the durable store.
- **Artifact** / **CacheEntry** — files in ActiveStorage (S3-compatible or
  local disk), served via 15-minute signed URLs.
- **Context** — named secret payloads, encrypted at rest with Rails
  `encrypts`. Raw values are never serialized anywhere.
- **RunnerToken** — only a SHA256 digest is stored; the raw token is shown
  once at creation.

### The claim protocol (component 4)

Runners poll `POST /api/v1/runner/jobs/claim` with their bearer token:

1. The server atomically claims the oldest `queued` job the token may run —
   matching `resource_class` (NULL matches anything) and a free
   `max_concurrency` slot on the project. On Postgres this is
   `SELECT … FOR UPDATE SKIP LOCKED` inside a transaction, so concurrent
   runners resolve the race without double-claims.
2. The claim response is the full **job payload**: id, name,
   `working_directory`, `executor`, `steps`, merged `environment` (executor
   env + context values, contexts win), `pipeline` sha/branch,
   `workflow_run_id`, `project_id`, and `repository: { url, sha, branch }`.
3. The runner `POST`s `start` when the container starts, `heartbeat` every
   ~15s while running, streams log chunks (`seq`-numbered, idempotent
   upserts), uploads artifacts/cache, then `POST`s `complete` with per-step
   results. On `success`, dependents whose `requires` are all satisfied move
   `pending → queued`; workflow and pipeline statuses roll up.

A job whose heartbeat is older than 120s (`JobRun::STALE_HEARTBEAT_AFTER`) is
reclaimed to `queued` by a Solid Queue recurring job (every 60s) — a crashed
runner never wedges the queue.

### GitHub App (component 3)

`push` / `pull_request` webhooks → HMAC-verified → `Github::SyncPipelineJob`
→ fetch `.circleci/config.yml` **at the event SHA** → compile → the same
`PipelineIntake` seam as the REST API → `pending` commit status → runners
claim → terminal status posted back. First push from an unknown repo
auto-creates its `Project`.

**Fork-PR secret gating:** PRs from forks (`head.repo != base.repo`) are
flagged and forcibly receive **zero contexts** — secrets can't leak into
untrusted fork code. Compile errors still create a failed pipeline with a
`failure` status so the author sees what broke.

## The runner (component 5)

Two standard-library-only daemons implement the same runner API: the default
Ruby runner (`runner/`, `net/http` and `open3`, no gems) and the opt-in Go runner
(`runner-go/`, no external Go modules). Go 1.27 builds static binaries for
`linux/amd64` and `linux/arm64`; macOS is for development/tests only. Go runner
hosts need neither Ruby nor a Go toolchain. The compiler gem and Rails control
plane stay Ruby; switching the execution daemon changes no database schema.

Select Go with the install command's `--implementation go`, not a control-plane
or database setting. Ruby remains the default while cutover gates are pending;
opt-in support does not establish completed production soak. Follow the
[Ruby-to-Go migration guide](../DEPLOY.md#ruby-to-go-runner-migration) for an
idle non-deploy canary, configuration preservation and rollback. Shared wire
behaviour is frozen in [the Go contract](../runner-go/CONTRACT.md); implementation
differences are documented in [the Go runner guide](../runner-go/README.md).

Per claimed job:

1. Pull primary + service images; create an isolated Docker network.
2. Start service containers first (reachable by container name), then the
   long-lived primary container.
3. Execute steps via `docker exec` in order:
   - `checkout` — clones `repository.url` at the pipeline SHA
     (falls back to `CHECKOUT_REPO_URL`).
   - `run` — shell exec with the step's env/workdir; `when: on_success /
     on_fail / always` evaluated at runtime.
   - `save_cache` / `restore_cache` — tarballs exchanged with the cache API;
     key templates (`{{ checksum "path" }}`, `{{ .Branch }}`, `{{ epoch }}`)
     resolved at runtime; restore tries keys in order (server does exact,
     then longest-prefix fallback); a clean miss never fails the job.
   - `store_artifacts` — per-file upload with `path` + `destination`.
   - `persist_to_workspace` / `attach_workspace` — layered on the cache API
     under a reserved `forge-ci-workspace/<workflow_run_id>/` namespace.
   - `store_test_results` / `add_ssh_keys` — skipped loudly, never failed.
4. Stream redacted log chunks (every env value ≥ `REDACT_MIN_LENGTH` chars is
   masked — secret redaction is the runner's job; the control plane stores
   log text verbatim).
5. Always clean up containers and the network, including failures and shutdown.
   Shutdown reports `canceled` by default; `REQUEUE_ON_SHUTDOWN` can instead
   requeue eligible interrupted jobs (never enable it on deploy runners).
   Go uses bounded cleanup and process-group interruption; see its documented
   [shutdown differences](../runner-go/README.md#deliberate-differences-from-the-ruby-runner).

## Secrets model (component 8)

| Layer | Protection |
|---|---|
| At rest | Context payloads and job context snapshots encrypted (Rails `encrypts`) |
| In API responses | Raw contexts never serialized; claim payload exposes only the merged `environment`; rotation returns key *names* only; UI renders `••••••` |
| Administration | Rotation needs a separate `FORGE_CI_ADMIN_TOKEN` (fail-closed); runner tokens can never read or rewrite secrets |
| In logs | Runner redacts known secret values before POSTing chunks |
| Fork PRs | Receive no context/project secrets; dedicated fork-only runner tokens cannot claim trusted jobs |

## Scaling

- **Runners** are the unit of scale: add hosts, generate a token per host
  (optionally per `resource_class`), done. No shared state between them.
- **Control plane** scales like any Rails app; the claim path is the hot
  spot and is a single indexed, row-locked query.
- **Storage** (logs/artifacts/cache) lives in S3-compatible object storage,
  never on the app disk in production.
