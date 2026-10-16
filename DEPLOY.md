# Deploying forge-ci

## Fastest path: docker compose

```sh
cp .env.example .env   # dev defaults work as-is; replace secrets for real use
docker compose up --build -d
```

This brings up Postgres, the control plane,
and the Solid Queue worker (object storage is AWS S3 — see §2).

Pick a runner secret first (any strong random value) and set it as
`RUNNER_TOKEN` — the server accepts the same value as its
`FORGE_CI_RUNNER_TOKEN`, so the runner connects with no further setup:

```sh
openssl rand -hex 32   # put it in .env as RUNNER_TOKEN
docker compose up -d runner
```

Web UI: http://localhost:3000

The rest of this guide covers production-style deployments (Coolify / manual
Docker). The compose file is also the best reference for the full env var
set — see [docs/configuration.md](docs/configuration.md).

## Architecture

```
                          ┌─────────────────────────┐
GitHub ──webhook──▶       │ Control plane (Rails 8) │──claim API──▶ ┌──────────────┐
(push/PR)                 │  + web UI (:80)         │◀─heartbeats── │ Runner host  │
                          │  + Solid Queue worker   │──log chunks──▶│ (Docker)     │
                          │                         │               └──────────────┘
                          │  Postgres 14+           │──claim API──▶ ┌──────────────┐
                          │  S3-compatible storage  │◀─heartbeats── │ Runner host  │
                          └─────────────────────────┘               │ (Docker)     │
                                                                    └──────────────┘
```

Runners need **outbound** HTTPS to the control plane only — no inbound ports.

## Requirements

| Piece | Minimum |
|---|---|
| Control plane host | 2 GB RAM, Docker (a Coolify-managed VPS works) |
| Postgres | 14+ (Coolify one-click Postgres, or any managed/external instance) |
| Object storage | AWS S3 — holds logs, artifacts, cache tarballs |
| Runner hosts (1+) | Docker Engine, Ruby ≥ 3.0, outbound HTTPS to the control plane |
| Domain | Public HTTPS URL for the control plane (**required** for GitHub webhooks) |

## 1. Postgres

Any Postgres 14+ works. You need **three databases** (or three schemas-worth
of separation): the app DB, the Solid Queue DB, and the cache DB — see
`QUEUE_DATABASE_URL` / `CACHE_DATABASE_URL` below. They must be *separate*
physical databases: `bin/rails db:prepare` skips loading `db/queue_schema.rb`
when the queue config resolves to an already-initialized database.

Example with Docker:

```sh
docker run -d --name forge-ci-pg --restart unless-stopped \
  -e POSTGRES_PASSWORD=<strong-password> \
  -v pgdata:/var/lib/postgresql/data \
  postgres:16
```

Connection URLs (the app creates the databases on first `db:prepare`, so the
role needs `CREATEDB` — or create them upfront):

```
DATABASE_URL=postgres://postgres:<strong-password>@<pg-host>:5432/forge_ci
QUEUE_DATABASE_URL=postgres://postgres:<strong-password>@<pg-host>:5432/forge_ci_queue
CACHE_DATABASE_URL=postgres://postgres:<strong-password>@<pg-host>:5432/forge_ci_cache
```

Each falls back to `DATABASE_URL` when its own URL isn't set — but then the
queue tables never load (see above), so set all three in production.

## 2. Object storage (AWS S3)

Job logs, artifacts, and cache tarballs live in S3. Create the bucket first
(the app does not create it for you):

```sh
aws s3 mb s3://forge-ci --region us-east-1
```

The app uses it via:

```
ACTIVE_STORAGE_SERVICE=amazon
AWS_S3_BUCKET=forge-ci
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=<access-key>
AWS_SECRET_ACCESS_KEY=<secret-key>
```

(`AWS_S3_ENDPOINT` / `AWS_S3_FORCE_PATH_STYLE` are only needed for
S3-compatible stores like MinIO — leave them unset for real AWS S3.)

## 3. Control plane

The root `Dockerfile` builds the production image from the repo root (it
understands the monorepo layout — the `forge-ci` gem is copied to `/forge-ci`
and `FORGE_CI_GEM_PATH` points bundler at it; `BUNDLE_FROZEN=false` is set
because the committed lockfile records the path as `..`). Thruster serves on
port 80.

```sh
docker build -t forge-ci-web .
docker run -d --name forge-ci-web --restart unless-stopped -p 80:80 \
  -e RAILS_ENV=production \
  -e DATABASE_URL="postgres://..." \
  -e QUEUE_DATABASE_URL="postgres://..." \
  -e CACHE_DATABASE_URL="postgres://..." \
  -e SECRET_KEY_BASE="<openssl rand -hex 64>" \
  -e FORGE_CI_UI_USER=admin -e FORGE_CI_UI_PASSWORD="<strong>" \
  -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="<from: bin/rails db:encryption:init>" \
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="<...>" \
  -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="<...>" \
  -e ACTIVE_STORAGE_SERVICE=amazon \
  -e AWS_S3_BUCKET=forge-ci \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=<...> -e AWS_SECRET_ACCESS_KEY=<...> \
  -e ARTIFACT_RETENTION_DAYS=30 \
  forge-ci-web
```

The entrypoint runs `db:prepare` on boot, which creates all three databases
and loads their schemas (`db/schema.rb`, `db/queue_schema.rb`).

### Background worker (required)

Stale-job reclaiming and artifact purging run on Solid Queue. Run the worker
alongside the web process:

```sh
# same image + env as above, command override:
docker run -d --name forge-ci-worker --restart unless-stopped \
  ... (same -e vars) ... \
  forge-ci-web ./bin/jobs
```

(On Coolify: a second service from the same image with the start command
overridden to `./bin/jobs`.)

### Full env var reference

| Variable | Required | Purpose |
|---|---|---|
| `DATABASE_URL` | yes | Postgres URL for the app DB (production) |
| `QUEUE_DATABASE_URL` / `CACHE_DATABASE_URL` | yes | Separate Postgres URLs for the Solid Queue / cache DBs (each falls back to `DATABASE_URL`, but then queue tables never load — set all three) |
| `SECRET_KEY_BASE` | yes | Rails secret (`openssl rand -hex 64`) |
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | yes (prod) | Web UI basic auth |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT` | yes (prod) | Context payload encryption |
| `ACTIVE_STORAGE_SERVICE` | yes | `amazon` (AWS S3) or `local` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `AWS_S3_BUCKET` | with `amazon` | Storage credentials (create the bucket first) |
| `AWS_S3_ENDPOINT` / `AWS_S3_FORCE_PATH_STYLE` | for S3-compatible stores | Endpoint override, e.g. MinIO (leave unset for real AWS S3) |
| `ARTIFACT_RETENTION_DAYS` | no (30) | Artifact retention |
| `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY` / `GITHUB_WEBHOOK_SECRET` | for GitHub | App auth (see §6) |
| `APP_HOST` | recommended | Public base URL, e.g. `https://ci.example.com` (commit-status links) |
| `FORGE_CI_ADMIN_TOKEN` | **yes** (for any non-GitHub use) | Bearer token for the admin API: create projects/contexts, rotate secrets, start/cancel pipelines (`forge-ci trigger`). Admin endpoints answer 503 while unset |
| `FORGE_CI_STREAM_TIMEOUT_SECONDS` | no (300) | SSE live-tail hold time |

## 4. Runner hosts

Each runner host needs Docker Engine and Ruby ≥ 3.0 (the runner is stdlib-only —
no gems to install). Copy the `runner/` directory over, then install as a
systemd service:

```ini
# /etc/systemd/system/forge-ci-runner.service
[Unit]
Description=forge-ci Docker runner
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
# (root, or a user in the docker group)
Environment=CONTROL_PLANE_URL=https://ci.example.com
Environment=RUNNER_TOKEN=<shared secret, same as the server's FORGE_CI_RUNNER_TOKEN>
Environment=RESOURCE_CLASS=medium
Environment=POLL_INTERVAL=5
WorkingDirectory=/opt/forge-ci-runner
ExecStart=/usr/bin/ruby /opt/forge-ci-runner/bin/forge-ci-runner
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now forge-ci-runner
sudo journalctl -u forge-ci-runner -f   # watch it poll
```

Generate one token per host (or per resource class) in the Rails console:

```ruby
record, raw = RunnerToken.generate!(name: "worker-1", resource_class: "medium")
puts raw  # save it — only the digest is stored
```

Scale by adding hosts. A crashed runner simply stops heartbeating and its job
is reclaimed after 120s.

## 5. GitHub App

With the control plane on its public HTTPS URL, follow the checklist in
[`web/README.md`](web/README.md) ("GitHub App setup"): register the app
(webhook URL `https://<your-host>/api/v1/github/webhooks`), set the four
`GITHUB_*` env vars, install it on the account. First push from a repo
auto-creates its forge-ci project.

## 6. Smoke test

1. Add `.circleci/config.yml` to a test repo (start from the compiler fixture
   `test/fixtures/full.yml`).
2. Push to GitHub.
3. Watch the pipeline in the web UI (`/projects/:id/pipelines/:id`) and confirm
   the commit status turns green on the commit.
4. Check a job's log viewer, then an artifact download.

## 7. Operations

- **Updating**: `git pull`, rebuild the image, recreate the containers.
  Runners pick up nothing cached — they're stateless.
- **Backups**: Postgres dumps + the S3 bucket. Everything else is
  disposable.
- **Retention**: artifacts purge after `ARTIFACT_RETENTION_DAYS` (Solid Queue
  daily job); logs live on blobs indefinitely until you add a policy.
- **Logs**: `docker logs forge-ci-web`, `journalctl -u forge-ci-runner`.
- **Security notes**: never expose Postgres publicly; rotate
  `FORGE_CI_ADMIN_TOKEN` and runner tokens if leaked; fork PRs never receive
  contexts (enforced in code).
