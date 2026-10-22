# Configuration reference

Every environment variable ForgeCI understands, per component. A production
server needs none of them except `DATABASE_URL` (set by `docker-compose.yml`)
and, for a public deploy, `APP_HOST`. Secrets left unset are generated on
first boot and kept in `secrets.yml` in the data directory.

## Control plane (`web/`)

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | — (required in production) | Postgres URL for the app database |
| `QUEUE_DATABASE_URL` / `CACHE_DATABASE_URL` | `DATABASE_URL` with `_queue` / `_cache` appended to the database name | Solid Queue and cache databases; each must be a separate database |
| `APP_HOST` | the request's host | Public base URL, e.g. `https://ci.example.com`: webhooks, commit-status links, the runner install command |
| `FORCE_SSL` | `false` | `true` behind an HTTPS proxy: Secure session cookie, HSTS, HTTPS redirects |
| `FORGE_CI_DATA_DIR` | `web/storage` (`/rails/storage` in the image, the `forge-ci-data` volume) | Where generated secrets (`secrets.yml`), `runner-token` and `initial-admin-password` are written |
| `SECRET_KEY_BASE` | generated | Rails secret |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` / `_DETERMINISTIC_KEY` / `_KEY_DERIVATION_SALT` | generated (insecure fixed keys outside production) | Encryption of contexts and the stored GitHub App credentials |
| `FORGE_CI_ADMIN_TOKEN` | generated | Bearer token for the admin API and `forge-ci trigger`; shown under Settings |
| `FORGE_CI_RUNNER_TOKEN` | generated | Shared runner secret; runners presenting it authenticate as `static-runner`. Shown in the Settings install command |
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | `admin` with a generated password printed in the logs (`admin` / `password` in development) | The first admin, created only while there are no users |
| `ACTIVE_STORAGE_SERVICE` | `local` | Where logs, artifacts and caches go: `local` (the data volume) or `amazon` (S3 or compatible) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | — | S3 credentials (with `amazon`), also used for autoscaling |
| `AWS_REGION` | `us-east-1` | S3 region |
| `AWS_S3_BUCKET` | — | S3 bucket (with `amazon`); create it first |
| `AWS_S3_ENDPOINT` / `AWS_S3_FORCE_PATH_STYLE` | — / `false` | For S3-compatible stores such as MinIO |
| `GITHUB_APP_ID` / `GITHUB_APP_PRIVATE_KEY` / `GITHUB_WEBHOOK_SECRET` | the App from Settings → Connect GitHub | An App you registered yourself; these take precedence over the stored one. The webhook endpoint rejects everything while no secret is set |
| `ARTIFACT_RETENTION_DAYS` | `30` | Artifact retention (`PurgeOldArtifactsJob` runs daily at 03:00) |
| `FORGE_CI_STREAM_TIMEOUT_SECONDS` | `25` | How long one SSE log live-tail request stays open before the job page reconnects. Each open stream holds a web thread, so keep it short |
| `FORGE_CI_AUTOSCALE` | — | Scale runner Auto Scaling Groups up when jobs queue: `class=asg-name[:max[:jobs_per_instance]],…` (see DEPLOY.md, "Scale runners to zero") |
| `FORGE_CI_AUTOSCALE_REGION` | `AWS_REGION` | Region of those Auto Scaling Groups |
| `SOLID_QUEUE_IN_PUMA` | `1` in the image | Run the background jobs inside the web process. Unset it to run `bin/jobs` separately |
| `FORGE_CI_RUNNER_PATH` | `/forge-ci/runner` in the image, `../runner` otherwise | The runner files served as `/runner.tar.gz` |
| `FORGE_CI_SEED_DEMO` | — | `1` loads the demo project and pipelines in production (`db:prepare` skips them otherwise) |
| `RAILS_MAX_THREADS` | `16` in the image (`3` otherwise) | Web request threads, and the database pool size |

## Runner (`runner/`)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CONTROL_PLANE_URL` | yes | — | Base URL of the control plane |
| `RUNNER_TOKEN` | yes, or `RUNNER_TOKEN_FILE` | — | The server's runner token (Settings → Runners), or a per-host token |
| `RUNNER_TOKEN_FILE` | no | — | Read the token from this file instead, e.g. the `runner-token` file the server writes to its data volume |
| `RESOURCE_CLASS` | no | token's class, else any | Passed to the claim endpoint; the server matches jobs on it |
| `POLL_INTERVAL` | no | `5` | Idle poll interval, seconds (backoff base) |
| `MAX_IDLE_INTERVAL` | no | `60` | Idle backoff cap, seconds |
| `HEARTBEAT_INTERVAL` | no | `15` | Heartbeat interval while running (server reclaims after 120s) |
| `LOG_CHUNK_SIZE` | no | `65536` | Bytes per log chunk |
| `CHECKOUT_REPO_URL` | no | — | Fallback git URL for `checkout` (the claim payload's `repository.url` is preferred) |
| `REDACT_MIN_LENGTH` | no | `8` | Env values shorter than this are not redacted from logs |
| `DOCKER_BIN` | no | `docker` | Path to the docker CLI |
| `IDLE_SHUTDOWN_AFTER` | no | `0` (never) | Seconds without a job after which the runner stops claiming, runs `IDLE_SHUTDOWN_COMMAND` and exits |
| `IDLE_SHUTDOWN_COMMAND` | no | — | Shell command run once on idle shutdown, e.g. `bin/forge-ci-asg-terminate-self` |

## Compiler gem / CLI

No configuration. `forge-ci validate|compile` takes flags (`--branch`,
`--sha`, `--number`, `--json`); the library takes `pipeline_params:`.
