# forge-ci TODO

The MVP (all 8 components) is code-complete and tested. This list is what's
left to take it from "works" to "runs in production" and beyond — in rough
priority order. Check items off as they land.

## To launch (blockers)

- [x] **Docker Compose** for the full stack (`docker-compose.yml`: Postgres,
      MinIO, control plane, Solid Queue worker, runner) — 2026-10-16
- [x] **Solid Queue installed** (`db/queue_schema.rb`, `config/queue.yml`,
      `bin/jobs`; per-DB `QUEUE_DATABASE_URL`/`CACHE_DATABASE_URL`) — 2026-10-16
- [ ] **Deploy the control plane** with a public HTTPS URL ([DEPLOY.md](DEPLOY.md))
- [ ] **Postgres in production** — SQLite is dev-only; the atomic claim path
      (`FOR UPDATE SKIP LOCKED`) needs Postgres
- [ ] **S3-compatible storage** for logs/artifacts/cache (MinIO self-hosted or AWS S3)
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

- [ ] Real UI auth (login, RBAC) — v1 is HTTP basic auth via env vars
- [ ] Auth on the raw pipeline-intake endpoint (currently unauthenticated;
      the GitHub flow goes through the HMAC-verified webhook instead)
- [ ] Pipeline cancel API (cancel a running pipeline from the UI/API)
- [ ] Per-branch context scoping (v1: a context is all-or-nothing per project)
- [ ] Audit log for secret rotation
- [ ] Log blob delta-append (each chunk POST currently rewrites the whole blob)
- [ ] Runner: per-step timeouts (a hung step hangs until killed)
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
- [ ] `parallelism` + timing-based test splitting
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
