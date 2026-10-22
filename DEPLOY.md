# Deploying forge-ci

- [Fastest path: docker compose](#fastest-path-docker-compose)
- [Requirements](#requirements)
- [1. Postgres](#1-postgres) · [2. Object storage](#2-object-storage-aws-s3) · [3. Control plane](#3-control-plane)
- [4. Runner hosts](#4-runner-hosts), including [scaling runners to zero](#scale-runners-to-zero-aws)
- [5. GitHub App](#5-github-app), or [use it without the GitHub App](#use-it-without-the-github-app)
- [6. Smoke test](#6-smoke-test) · [7. Operations](#7-operations)

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
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | first boot only | Creates the first **admin** account when no users exist. After signing in, change the password under *Account* (or add users under *Users*); you can then remove these variables |
| `FORCE_SSL` | recommended | `true` behind an HTTPS proxy: Secure session cookie, HSTS, HTTPS redirects |
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
no gems to install). Copy the `runner/` directory to `/opt/forge-ci-runner`,
then install the bundled systemd unit:

```sh
sudo cp /opt/forge-ci-runner/forge-ci-runner.service /etc/systemd/system/
# edit the CONTROL_PLANE_URL and RUNNER_TOKEN lines, then:
sudo systemctl daemon-reload
sudo systemctl enable --now forge-ci-runner
```

The unit file (`runner/forge-ci-runner.service`):

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
# Scale to zero: stop after 10 idle minutes and remove this instance from its
# Auto Scaling Group (see "Scale runners to zero" below).
#Environment=IDLE_SHUTDOWN_AFTER=600
#Environment=IDLE_SHUTDOWN_COMMAND=/opt/forge-ci-runner/bin/forge-ci-asg-terminate-self
WorkingDirectory=/opt/forge-ci-runner
ExecStart=/usr/bin/ruby /opt/forge-ci-runner/bin/forge-ci-runner
# on-failure, not always: an idle shutdown exits 0 and must stay stopped.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now forge-ci-runner
sudo journalctl -u forge-ci-runner -f   # watch it poll
```

`RESOURCE_CLASS` routes jobs: a runner only claims jobs whose
`resource_class:` matches it, plus jobs with none. With the shared
`RUNNER_TOKEN` each host just sets its own `RESOURCE_CLASS` (e.g. `spot`
for interruptible check runners, `deploy` for an on-demand deploy runner);
a per-host token's own class, if it has one, takes precedence.

Or generate one token per host (or per resource class) in the Rails console:

```ruby
record, raw = RunnerToken.generate!(name: "worker-1", resource_class: "medium")
puts raw  # save it — only the digest is stored
```

Scale by adding hosts. A crashed runner simply stops heartbeating and its job
is reclaimed after 120s.

Steps are killed after `STEP_NO_OUTPUT_TIMEOUT` seconds without output
(default 600; a step's own `no_output_timeout:` wins) and jobs after
`JOB_TIMEOUT` (default 3600). Both are runner settings.

### Scale runners to zero (AWS)

Runners can cost nothing while nobody is pushing. Each resource class gets an
EC2 Auto Scaling Group with a minimum of 0. The control plane raises a
group's desired capacity when jobs of that class queue, and an idle runner
removes its own instance when it has had no work for a while.

Scaling down is always done by the runner, after it has stopped claiming, so
a scale-in never cuts a job short. The control plane only ever scales up.

**1. Store the runner token in SSM** so it isn't in the launch template:

```sh
aws ssm put-parameter --name /forge-ci/runner-token --type SecureString --value "$RUNNER_TOKEN"
```

**2. Create a launch template per group.** Use Ubuntu 22.04 or 24.04
(Graviton `t4g`/`c7g` work well) and an instance profile allowing:

- `ssm:GetParameter` on `/forge-ci/runner-token`, plus `kms:Decrypt` for its key;
- `autoscaling:TerminateInstanceInAutoScalingGroup` on the runner groups;
- whatever your jobs themselves need (for a deploy runner, its deploy permissions).

For user data, use [`runner/aws/user-data.sh`](runner/aws/user-data.sh) with
its four settings edited: control plane URL, `RESOURCE_CLASS`, the SSM
parameter name and `IDLE_SHUTDOWN_AFTER`. It installs Docker, Ruby and the
AWS CLI, then starts the runner with
`IDLE_SHUTDOWN_COMMAND=bin/forge-ci-asg-terminate-self`.

**3. Create the Auto Scaling Groups** with minimum 0, desired 0 and a maximum
of your choice. For interruptible check runners, use a mixed-instances policy
on Spot. A deploy runner can scale to zero as well, on on-demand instances.
An idle shutdown never interrupts a job, but a Spot reclaim can.

**4. Tell the control plane about the groups** (on the web and worker
processes):

```
FORGE_CI_AUTOSCALE=spot=ci-spot-runners:4,deploy=ci-deploy-runner:1
FORGE_CI_AUTOSCALE_REGION=ap-southeast-3   # if the groups aren't in AWS_REGION
```

Each entry is `resource_class=asg-name[:max[:jobs_per_instance]]`. Jobs with
no `resource_class` count toward the first entry. The control plane's AWS
credentials (the same `AWS_*` variables as S3) need
`autoscaling:DescribeAutoScalingGroups` and `autoscaling:SetDesiredCapacity`
on those groups.

The `scale_runners` job checks every 30 seconds. It raises a group to cover
that class's queued and running jobs (one instance per `jobs_per_instance`
jobs, capped at `max`) and never lowers it.

**What to expect:**
- **Cold start:** the first job after an idle period waits for an instance to
  boot and pull its image, typically 1–3 minutes. Later jobs reuse the warm
  runner until it has been idle for `IDLE_SHUTDOWN_AFTER`.
- **Another cloud or your own autoscaler:** `GET /api/v1/queue` (admin token)
  returns queued and running counts per resource class for it to act on.

## 5. GitHub App

With the control plane on its public HTTPS URL, follow the checklist in
[`web/README.md`](web/README.md) ("GitHub App setup"): register the app
(webhook URL `https://<your-host>/api/v1/github/webhooks`), set the four
`GITHUB_*` env vars, install it on the account. First push from a repo
auto-creates its forge-ci project.

Private repositories need nothing extra: each claim carries a short-lived
installation token that the runner uses for `checkout`, sent as an HTTP header
only for the fetch, so it never reaches `.git/config` or the job's steps.

## Use it without the GitHub App

Drive ForgeCI from any CI system or script with the admin API and the
`forge-ci` CLI. Set `FORGE_CI_ADMIN_TOKEN` on the control plane
(`openssl rand -hex 32`), then:

```sh
export FORGE_CI_URL=https://ci.example.com FORGE_CI_ADMIN_TOKEN=...

# Once: a project and, optionally, a secrets context.
curl -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"name":"myapp","repo_url":"https://github.com/me/myapp.git"}' $FORGE_CI_URL/api/v1/projects
curl -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"name":"prod","payload":{"DEPLOY_KEY":"..."}}' $FORGE_CI_URL/api/v1/projects/1/contexts

# Every run: compile .circleci/config.yml and start a pipeline for the current
# branch and commit. --wait blocks and exits non-zero if it fails.
forge-ci trigger .circleci/config.yml --project myapp --context prod --wait
forge-ci cancel 42
```

For a private repository without the App, set `CHECKOUT_REPO_URL` on the
runner with a token embedded
(`https://x-access-token:TOKEN@github.com/org/repo.git`) and leave the
project's `repo_url` empty, because a project `repo_url` takes precedence.
The full API is in [docs/api.md](docs/api.md).

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
