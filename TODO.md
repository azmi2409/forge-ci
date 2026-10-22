# forge-ci TODO

The MVP (all 8 components) is code-complete and tested. This list is what's
left to take it from "works" to "runs in production" and beyond — in rough
priority order. Check items off as they land.

## To launch (blockers)

- [x] **Docker Compose** for the full stack (`docker-compose.yml`: Postgres,
      control plane, Solid Queue worker, runner; AWS S3 for storage) — 2026-10-16
- [x] **Solid Queue installed** (`db/queue_schema.rb`, `config/queue.yml`,
      `bin/jobs`; per-DB `QUEUE_DATABASE_URL`/`CACHE_DATABASE_URL`) — 2026-10-16
- [ ] **Deploy the control plane** with a public HTTPS URL ([DEPLOY.md](DEPLOY.md))
- [ ] **Postgres in production** — SQLite is dev-only; the atomic claim path
      (`FOR UPDATE SKIP LOCKED`) needs Postgres
- [ ] **S3 bucket** for logs/artifacts/cache (AWS S3; create the bucket before deploying)
- [ ] **Register the GitHub App** and install it on the account
      (blocked on the public URL; checklist in `web/README.md`)
- [ ] **Generate production secrets**: `ACTIVE_RECORD_ENCRYPTION_*` keys
      (`bin/rails db:encryption:init`), `GITHUB_WEBHOOK_SECRET`,
      `FORGE_CI_ADMIN_TOKEN`, `FORGE_CI_UI_USER`/`FORGE_CI_UI_PASSWORD`
      (the app refuses to boot the UI without them in production)
- [ ] **Provision runner host(s)** with Docker Engine; deploy the runner daemon
      (systemd unit in [DEPLOY.md](DEPLOY.md))
- [ ] **Create runner tokens** per host (`RunnerToken.generate!` in console)
- [ ] **Smoke test**: push to a test repo → pipeline runs end to end →
      green commit status on GitHub

## Hardening

- [x] Real UI auth: users, session login/logout, roles (admin/member), lockout, password change, user admin — 2026-10-16
- [x] Auth on the raw pipeline-intake endpoint (admin bearer token) — 2026-10-16
- [x] Pipeline cancel (API, CLI `forge-ci cancel`, UI button; runners stop on heartbeat) — 2026-10-16
- [x] Admin API for projects/contexts + `forge-ci trigger [--wait]` so CI can be
      driven without the GitHub App or a Rails console — 2026-10-16
- [x] Failed jobs cancel their dependents; pipeline only finishes when nothing is in flight — 2026-10-16
- [ ] Per-branch context scoping (v1: a context is all-or-nothing per project)
- [ ] Audit log for secret rotation
- [ ] Log blob delta-append (each chunk POST currently rewrites the whole blob)
- [x] Runner: no-output step timeout + job timeout, per-step `environment:` — 2026-10-16
- [x] Runner: bash default shell, `$BASH_ENV`, `CIRCLE_*` built-in env vars — 2026-10-22
- [ ] Runner: `setup_remote_docker` (Docker access for jobs, e.g. deploys)
- [ ] Runner: container CPU/memory limits
- [ ] Runner: `store_test_results` (JUnit → timing DB) and `add_ssh_keys`
- [ ] Publish the `forge-ci` gem to RubyGems (then `web/` can depend on the
      released gem instead of the path gem — also unblocks clean Docker builds)

## Feature backlog (deferred from the original REA)

- [ ] `machine` executor (full VM per job)
- [ ] `macos` / `windows` executors
- [ ] GPU resource classes
- [ ] Orb registry (local orbs first, then a registry)
- [ ] Dynamic config (`setup:` workflows + `pipeline.continue`)
- [x] `parallelism` + `circleci tests glob|split|run` (name/filesize) — 2026-10-22
- [ ] Timing-based test splitting (needs `store_test_results` → timing DB)
- [ ] Scheduled (cron) pipelines
- [ ] SSH re-run / rerun-from-failed
- [ ] Approval jobs (`type: approval`)
- [ ] Docker layer caching

## Known limitations (accepted for v1)

- Workspace manifest can race when parallel jobs persist concurrently
  (last write wins)
- Step results are matched to steps by name (duplicate step names collide)
- Secrets are not distinguished from plain env vars in the claim payload —
  the runner redacts all long values instead of just secrets
- `filters: tags:` is parsed but ignored (warning)
- The `~` in `working_directory` expands to `/root` (assumes root in containers)
