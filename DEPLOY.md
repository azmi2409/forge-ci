# Deploying forge-ci

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
| Object storage | MinIO (self-hosted) or AWS S3 — holds logs, artifacts, cache tarballs |
| Runner hosts (1+) | Docker Engine, Ruby ≥ 3.0, outbound HTTPS to the control plane |
| Domain | Public HTTPS URL for the control plane (**required** for GitHub webhooks) |

## 1. Postgres

Any Postgres 14+ works. Example with Docker:

```sh
docker run -d --name forge-ci-pg --restart unless-stopped \
  -e POSTGRES_PASSWORD=<strong-password> \
  -e POSTGRES_DB=forge_ci_production \
  -v pgdata:/var/lib/postgresql/data \
  postgres:16
```

Note the connection URL; it becomes `DATABASE_URL`:

```
postgres://postgres:<strong-password>@<pg-host>:5432/forge_ci_production
```

## 2. Object storage (MinIO)

```sh
docker run -d --name forge-ci-minio --restart unless-stopped \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=<access-key> -e MINIO_ROOT_PASSWORD=<secret-key> \
  -v miniodata:/data \
  minio/minio server /data --console-address ":9001"
```

Create a bucket (console at `:9001`, or `mc mb`), e.g. `forge-ci`. The app
uses it via:

```
ACTIVE_STORAGE_SERVICE=amazon
AWS_ENDPOINT=http://<minio-host>:9000
AWS_BUCKET=forge-ci
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=<access-key>
AWS_SECRET_ACCESS_KEY=<secret-key>
```

(Omit `AWS_ENDPOINT` for real AWS S3.)

## 3. Control plane

The shipped `web/Dockerfile` is a standard Rails 8 production image (Thruster
serves on port 80). **One gotcha:** `web/Gemfile` references the compiler as a
path gem (`gem "forge-ci", path: "../forge-ci"`), which doesn't exist inside a
`web/`-context Docker build. Until the gem is published to RubyGems, vendor
the built gem:

```sh
cd /path/to/forge-ci
gem build forge-ci.gemspec                      # → forge-ci-0.1.0.gem
mkdir -p web/vendor/cache
cp forge-ci-0.1.0.gem web/vendor/cache/
# in web/Gemfile, replace the path line with:
#   gem "forge-ci", "0.1.0"
```

(`vendor/cache` is picked up by `bundle install --local`; the Dockerfile
already copies `vendor/`.) Then build and run with `web/` as the build context:

```sh
cd web
docker build -t forge-ci-web .
docker run -d --name forge-ci-web --restart unless-stopped -p 80:80 \
  -e RAILS_ENV=production \
  -e DATABASE_URL="postgres://..." \
  -e RAILS_MASTER_KEY="$(cat config/master.key)" \
  -e FORGE_CI_UI_USER=admin -e FORGE_CI_UI_PASSWORD="<strong>" \
  -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="<from: bin/rails db:encryption:init>" \
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="<...>" \
  -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="<...>" \
  -e ACTIVE_STORAGE_SERVICE=amazon \
  -e AWS_ENDPOINT=http://<minio-host>:9000 -e AWS_BUCKET=forge-ci \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=<...> -e AWS_SECRET_ACCESS_KEY=<...> \
  -e ARTIFACT_RETENTION_DAYS=30 \
  forge-ci-web
```

On Coolify, deploy `web/` as a Dockerfile app with the same env vars
(generate real values for every secret — the app refuses to boot the UI
without `FORGE_CI_UI_USER`/`FORGE_CI_UI_PASSWORD` in production, and dev
encryption keys are loudly insecure).

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
| `DATABASE_URL` | yes | Postgres URL (production) |
| `RAILS_MASTER_KEY` | yes | Rails credentials key |
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | yes (prod) | Web UI basic auth |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT` | yes (prod) | Context payload encryption |
| `ACTIVE_STORAGE_SERVICE` | yes | `amazon` (S3/MinIO) or `local` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` / `AWS_BUCKET` | with `amazon` | Storage credentials |
| `AWS_ENDPOINT` | for MinIO | S3-compatible endpoint override |
| `ARTIFACT_RETENTION_DAYS` | no (30) | Artifact retention |
| `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY` / `GITHUB_WEBHOOK_SECRET` | for GitHub | App auth (see §6) |
| `APP_HOST` | recommended | Public base URL, e.g. `https://ci.example.com` (commit-status links) |
| `FORGE_CI_ADMIN_TOKEN` | for rotation | Bearer token for context rotation API |
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
Environment=RUNNER_TOKEN=<raw token from RunnerToken.generate!>
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
- **Backups**: Postgres dumps + the MinIO/S3 bucket. Everything else is
  disposable.
- **Retention**: artifacts purge after `ARTIFACT_RETENTION_DAYS` (Solid Queue
  daily job); logs live on blobs indefinitely until you add a policy.
- **Logs**: `docker logs forge-ci-web`, `journalctl -u forge-ci-runner`.
- **Security notes**: never expose Postgres publicly; rotate
  `FORGE_CI_ADMIN_TOKEN` and runner tokens if leaked; fork PRs never receive
  contexts (enforced in code).
