# forge-ci TODO

The MVP (all 8 components) is code-complete and tested. This list is what's
left to take it from "works" to "runs in production" and beyond — in rough
priority order. Check items off as they land.

## Tested so far

ForgeCI runs one production project (KilatHost/web). That setup is the only
one tested end to end:

- **Runners:** AWS EC2 Spot instances in an Auto Scaling Group
  (`ap-southeast-3`, Ubuntu 24.04, x86), scaled from zero by
  `FORGE_CI_AUTOSCALE`. An on-demand Graviton (`t4g`) deploy group with
  `setup_remote_docker` is set up but not yet proven end to end.
- **Control plane:** Docker Compose on Coolify (Oracle Cloud), Postgres,
  logs on the local volume.

Anything else is untested: other clouds' VMs, bare metal, the compose
`RUNNERS=` runner in production, S3 storage, arm64 check runners. Expect
rough edges there and please report them.

## To launch (blockers)

- [x] **Docker Compose** for the full stack (`docker-compose.yml`: Postgres,
      control plane, Solid Queue worker, runner; AWS S3 for storage) — 2026-10-16
- [x] **Solid Queue installed** (`db/queue_schema.rb`, `config/queue.yml`,
      `bin/jobs`; per-DB `QUEUE_DATABASE_URL`/`CACHE_DATABASE_URL`) — 2026-10-16
- [x] **Deploy the control plane** with a public HTTPS URL (Coolify) — 2026-10-22
- [x] **Postgres in production**; queue and cache databases derived from `DATABASE_URL` — 2026-10-22
- [x] **Storage**: local volume by default, S3 optional — 2026-10-22
- [x] **GitHub App** through Settings → Connect GitHub (manifest flow) — 2026-10-22
- [x] **Production secrets** generated on first boot; first admin password
      printed, `forge_ci:reset_admin` to recover — 2026-10-22
- [x] **Runner hosts**: one-line install command, `RUNNERS=` on the server,
      AWS Spot Auto Scaling Groups — 2026-10-22
- [x] **Smoke test**: KilatHost/web pipelines run end to end with commit statuses — 2026-10-22

## Hardening

- [x] Real UI auth: users, session login/logout, roles (admin/member), lockout, password change, user admin — 2026-10-16
- [x] Auth on the raw pipeline-intake endpoint (admin bearer token) — 2026-10-16
- [x] Pipeline cancel (API, CLI `forge-ci cancel`, UI button; runners stop on heartbeat) — 2026-10-16
- [x] Admin API for projects/contexts + `forge-ci trigger [--wait]` so CI can be
      driven without the GitHub App or a Rails console — 2026-10-16
- [x] Failed jobs cancel their dependents; pipeline only finishes when nothing is in flight — 2026-10-16
- [ ] Per-branch context scoping (v1: a context is all-or-nothing per project)
- [ ] Audit log for secret rotation
- [x] Log blob written once when the job finishes, not on every chunk — 2026-10-22
- [x] Runner: no-output step timeout + job timeout, per-step `environment:` — 2026-10-16
- [x] Runner: bash default shell, `$BASH_ENV`, `CIRCLE_*` built-in env vars — 2026-10-22
- [x] Runner: `setup_remote_docker` on runners with `ALLOW_DOCKER_SOCKET=1`, never for forks — 2026-10-22
- [x] Scale runners to zero: idle self-shutdown, Auto Scaling Group scale-up, `GET /api/v1/queue` — 2026-10-22
- [x] Agent skill (`skills/forge-ci/SKILL.md`, `forge-ci skill install`) — 2026-10-22
- [ ] Runner: container CPU/memory limits
- [ ] Runner: `store_test_results` (JUnit → timing DB) and `add_ssh_keys`
- [x] Publish the `forge-ci` gem to RubyGems (0.1.0; 0.2.0 ready to push) — 2026-10-22
- [ ] Let `web/` depend on the released gem instead of the path gem (also
      unblocks clean Docker builds)

## Maintainer TODO (found running it for KilatHost/web)

Most important first.

- [ ] **Keep fork pull requests off privileged runners.** A fork PR can set
      `resource_class: deploy` and run commands on the deploy runner (it can't
      get `setup_remote_docker`, but the machine and anything it can reach are
      exposed). Refuse privileged classes for forked pipelines at intake or claim.
- [ ] **Don't store context secrets in `job_runs.context_environment` in
      plain text.** Read them at claim time like project variables, or encrypt
      the column.
- [ ] **Spot interruptions:** watch the 2-minute EC2 notice and hand the job
      back to the queue instead of failing it. Today an interrupted job
      shows as failed and needs a manual rerun.
- [ ] **Retry jobs killed by infrastructure** (runner lost mid-job) when the
      job is marked safe to retry; today stale running jobs are failed on
      purpose so a half-done deploy is never repeated.
- [ ] **Autoscaling beyond AWS:** `RunnerAutoscaler` only drives EC2 Auto
      Scaling Groups. Add a provider interface (OCI instance pools, GCP MIGs,
      Hetzner) or document `GET /api/v1/queue` for custom scalers.
- [x] **Build cache for `setup_remote_docker`:** done 2026-10-23 —
      `docker_layer_caching: true` + `FORGE_CI_BUILD_CACHE_REGISTRY` give jobs
      a registry-backed layer cache (buildx `--cache-from/--cache-to`,
      `forge-ci-build` wrapper, ECR token minting; docs/configuration.md,
      "Docker layer caching"). Kamal: `builder: cache: type=registry` reading
      `ENV["FORGE_CI_BUILD_CACHE_TO"]`.
- [ ] **AMI builder in the repo:** the runner image (Docker, Ruby, AWS CLI,
      pre-pulled job images) is built with a pasted script; ship it as
      `runner/aws/build-ami.sh` (and arm64), and the Spot group setup as a
      script too.
- [ ] **`circleci tests` needs bash:** the helper fails in images without bash
      (alpine). Make it POSIX sh.
- [ ] **Run ForgeCI's own CI on ForgeCI:** GitHub Actions minutes ran out and
      PRs merged with CI still queued. Add a `.circleci/config.yml` for this
      repo and dogfood it.
- [ ] **Pipeline page rendered empty once** (header only, no workflow card)
      and came back by itself; not reproduced. Investigate if it recurs.
- [ ] **"Took" counts from the first run:** after a rerun, the pipeline's
      duration includes the time before the rerun.
- [ ] **Huge logs:** the job page loads and renders the whole log; add
      truncation or paging for multi-MB logs.
- [ ] **Silence the `image_processing` warning** printed on every boot
      (`config.active_storage.variant_processor = :disabled`).
- [ ] **Multi-node control plane:** untested; local disk storage and the
      in-process cable fallback assume one node (use S3 and Postgres).

## Feature backlog (deferred from the original REA)

- [ ] `machine` executor (full VM per job)
- [ ] `macos` / `windows` executors
- [ ] GPU resource classes
- [ ] Orb registry (local orbs first, then a registry)
- [ ] Dynamic config (`setup:` workflows + `pipeline.continue`)
- [x] `parallelism` + `circleci tests glob|split|run` (name/filesize) — 2026-10-22
- [ ] Timing-based test splitting (needs `store_test_results` → timing DB)
- [ ] Scheduled (cron) pipelines
- [x] Rerun failed jobs / rerun all (pipeline page) — 2026-10-22
- [ ] SSH re-run
- [ ] Approval jobs (`type: approval`)
- [x] Docker layer caching — 2026-10-23, registry-backed via
      `docker_layer_caching: true` (see docs/configuration.md)

## Known limitations (accepted for v1)

- Workspace manifest can race when parallel jobs persist concurrently
  (last write wins)
- Step results are matched to steps by name (duplicate step names collide)
- Secrets are not distinguished from plain env vars in the claim payload —
  the runner redacts all long values instead of just secrets
- `filters: tags:` is parsed but ignored (warning)
- The `~` in `working_directory` expands to `/root` (assumes root in containers)
