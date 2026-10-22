# Configuration reference

Every environment variable forge-ci understands, per component. Anything
marked **required** fails fast (or refuses to boot) when missing in
production.

## Control plane (`web/`)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `DATABASE_URL` | yes (prod) | — | Postgres URL for the app DB |
| `QUEUE_DATABASE_URL` / `CACHE_DATABASE_URL` | yes (prod) | `DATABASE_URL` | Separate Postgres URLs for the Solid Queue / cache DBs — must be separate physical DBs for `db:prepare` to load their schemas |
| `SECRET_KEY_BASE` | yes (prod) | — | Rails secret (`openssl rand -hex 64`) |
| `RAILS_MASTER_KEY` | yes (prod) | — | Rails credentials key |
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | yes (prod) | `admin` / `password` (dev only, loud warning) | Bootstrap for the first admin account (only used while there are no users) |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_STORAGE_SERVICE` | yes (prod) | `local` | `amazon` (AWS S3) or `local` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | with `amazon` | — | Storage credentials |
| `AWS_REGION` | with `amazon` | `us-east-1` | Storage region |
| `AWS_S3_BUCKET` | with `amazon` | — | Storage bucket |
| `AWS_S3_ENDPOINT` | for S3-compatible stores | — | Endpoint override, e.g. MinIO at `http://minio:9000` (leave unset for AWS S3) |
| `AWS_S3_FORCE_PATH_STYLE` | for S3-compatible stores | `false` | Set `true` for MinIO / path-style stores |
| `ARTIFACT_RETENTION_DAYS` | no | `30` | Artifact retention (`PurgeOldArtifactsJob` runs daily 03:00) |
| `GITHUB_APP_ID` | for GitHub | — | Numeric GitHub App ID |
| `GITHUB_APP_PRIVATE_KEY` | for GitHub | — | App private key, PEM text (may contain newlines) |
| `GITHUB_WEBHOOK_SECRET` | for GitHub | — | Webhook HMAC secret — **fail-closed**: the endpoint 401s everything when blank |
| `APP_HOST` | recommended | — | Public base URL, e.g. `https://ci.example.com` (commit-status links) |
| `FORGE_CI_ADMIN_TOKEN` | for rotation | — | Bearer token for context rotation — **fail-closed** (503 when blank) |
| `FORGE_CI_STREAM_TIMEOUT_SECONDS` | no | `300` | How long the SSE log live-tail waits for output |
| `RAILS_MAX_THREADS` | no | `5` | DB pool size |
| `FORGE_CI_AUTOSCALE` | no | — | Scale runner Auto Scaling Groups up when jobs queue: `class=asg-name[:max[:jobs_per_instance]],…` (see DEPLOY.md, "Scale runners to zero") |
| `FORGE_CI_AUTOSCALE_REGION` | no | `AWS_REGION` | Region of those Auto Scaling Groups |

Generate encryption keys with `bin/rails db:encryption:init`.

## Runner (`runner/`)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CONTROL_PLANE_URL` | yes | — | Base URL of the control plane |
| `RUNNER_TOKEN` | yes (runner) | — | Shared runner secret (same value as the server's `FORGE_CI_RUNNER_TOKEN`) |
| `FORGE_CI_RUNNER_TOKEN` | to enable (server) | — | Operator-chosen runner secret; runners presenting it authenticate as `static-runner` (no per-token provisioning needed) |
| `RESOURCE_CLASS` | no | token's class | Passed to the claim endpoint; the server matches jobs on it |
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
