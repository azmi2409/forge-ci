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
| `FORGE_CI_UI_USER` / `FORGE_CI_UI_PASSWORD` | yes (prod) | `admin` / `password` (dev only, loud warning) | Web UI basic auth |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | yes (prod) | insecure dev key (loud warning) | Context payload encryption |
| `ACTIVE_STORAGE_SERVICE` | yes (prod) | `local` | `amazon` (S3/MinIO) or `local` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | with `amazon` | — | Storage credentials |
| `AWS_REGION` | with `amazon` | `us-east-1` | Storage region |
| `AWS_S3_BUCKET` | with `amazon` | — | Storage bucket |
| `AWS_S3_ENDPOINT` | for MinIO | — | S3-compatible endpoint, e.g. `http://minio:9000` |
| `AWS_S3_FORCE_PATH_STYLE` | for MinIO | `false` | Set `true` for MinIO / path-style stores |
| `ARTIFACT_RETENTION_DAYS` | no | `30` | Artifact retention (`PurgeOldArtifactsJob` runs daily 03:00) |
| `GITHUB_APP_ID` | for GitHub | — | Numeric GitHub App ID |
| `GITHUB_APP_PRIVATE_KEY` | for GitHub | — | App private key, PEM text (may contain newlines) |
| `GITHUB_WEBHOOK_SECRET` | for GitHub | — | Webhook HMAC secret — **fail-closed**: the endpoint 401s everything when blank |
| `APP_HOST` | recommended | — | Public base URL, e.g. `https://ci.example.com` (commit-status links) |
| `FORGE_CI_ADMIN_TOKEN` | for rotation | — | Bearer token for context rotation — **fail-closed** (503 when blank) |
| `FORGE_CI_STREAM_TIMEOUT_SECONDS` | no | `300` | How long the SSE log live-tail waits for output |
| `RAILS_MAX_THREADS` | no | `5` | DB pool size |

Generate encryption keys with `bin/rails db:encryption:init`.

## Runner (`runner/`)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `CONTROL_PLANE_URL` | yes | — | Base URL of the control plane |
| `RUNNER_TOKEN` | yes | — | Raw runner token (Bearer auth) |
| `RESOURCE_CLASS` | no | token's class | Passed to the claim endpoint; the server matches jobs on it |
| `POLL_INTERVAL` | no | `5` | Idle poll interval, seconds (backoff base) |
| `MAX_IDLE_INTERVAL` | no | `60` | Idle backoff cap, seconds |
| `HEARTBEAT_INTERVAL` | no | `15` | Heartbeat interval while running (server reclaims after 120s) |
| `LOG_CHUNK_SIZE` | no | `65536` | Bytes per log chunk |
| `CHECKOUT_REPO_URL` | no | — | Fallback git URL for `checkout` (the claim payload's `repository.url` is preferred) |
| `REDACT_MIN_LENGTH` | no | `8` | Env values shorter than this are not redacted from logs |
| `DOCKER_BIN` | no | `docker` | Path to the docker CLI |

## Compiler gem / CLI

No configuration. `forge-ci validate|compile` takes flags (`--branch`,
`--sha`, `--number`, `--json`); the library takes `pipeline_params:`.
