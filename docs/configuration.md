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
| `FORGE_CI_AUTOSCALE_WARM` | — | Classes (comma-separated, e.g. `deploy`) whose runner starts as soon as a pipeline has a job of that class waiting on earlier jobs, instead of once it's queued. The runner stays up until the job arrives, and idles out as usual if the job is canceled |
| `FORGE_CI_BUILD_CACHE_REGISTRY` | — | Full repository reference (no tag) of the registry-backed Docker layer cache for `setup_remote_docker` jobs, e.g. `123456789012.dkr.ecr.ap-southeast-3.amazonaws.com/forge-ci-cache`. See "Docker layer caching" below |
| `FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME` / `FORGE_CI_BUILD_CACHE_REGISTRY_PASSWORD` | — | Static credentials for a non-ECR cache registry (a machine user with push access to that one repository). ECR hosts are authorized automatically and ignore these |
| `SOLID_QUEUE_IN_PUMA` | `1` in the image, `0` in docker-compose.yml | Run the background jobs inside the web process. `0` (or empty) turns it off; then run `bin/jobs` separately, as the compose `worker` service does |
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
| `LOG_FLUSH_INTERVAL` | no | `1` | Send buffered output at least this often (seconds), so the job page shows it live |
| `CHECKOUT_REPO_URL` | no | — | Fallback git URL for `checkout` (the claim payload's `repository.url` is preferred) |
| `REDACT_MIN_LENGTH` | no | `8` | Env values shorter than this are not redacted from logs |
| `DOCKER_BIN` | no | `docker` | Path to the docker CLI |
| `BUILDX_BIN` | no | — | Path to a buildx binary the runner copies into job images that lack one, for `docker_layer_caching` builds. Set automatically by the install command's `--allow-docker` and the runner image |
| `IDLE_SHUTDOWN_AFTER` | no | `0` (never) | Seconds without a job after which the runner stops claiming, runs `IDLE_SHUTDOWN_COMMAND` and exits |
| `IDLE_SHUTDOWN_COMMAND` | no | — | Shell command run once on idle shutdown, e.g. `bin/forge-ci-asg-terminate-self` |
| `ALLOW_DOCKER_SOCKET` | no | off | `1` lets jobs with `setup_remote_docker` use this machine's Docker socket. Such a job controls the machine, so set it only on runners trusted with that (the deploy runner); fork pull requests are always refused. The install command's `--allow-docker` sets it |
| `REQUEUE_ON_SHUTDOWN` | no | off | `1`: on SIGTERM/SIGINT mid-job, stop the running step and put the job back in the queue instead of reporting it canceled (at most twice per job). For Spot/preemptible runners whose jobs are safe to retry; never on deploy runners. The install command's `--requeue-on-shutdown` sets it |
| `DOCKER_SOCKET_PATH` | no | `/var/run/docker.sock` | The socket mounted for `setup_remote_docker` |

## Compiler gem / CLI

No configuration. `forge-ci validate|compile` takes flags (`--branch`,
`--sha`, `--number`, `--json`); the library takes `pipeline_params:`.

## Docker layer caching

Docker's layer cache lives in `/var/lib/docker` on the runner machine, so on
ephemeral (Spot, scale-to-zero) runners every fresh instance rebuilds every
layer. Setting this up moves the cache into a registry instead: builds export
their layers during the build (`--cache-to`) and the next runner pulls them
back (`--cache-from`), so a Spot reclamation never costs more than the build
it was interrupting.

**Server**: set `FORGE_CI_BUILD_CACHE_REGISTRY` to a full repository
reference without a tag. Cache images are tags on that one repository,
per project and branch: `<registry>:p<project_id>-<branch>`.

For ECR (any `*.dkr.ecr.<region>.amazonaws.com` host) the control plane
mints 12-hour authorization tokens itself, using the same AWS credentials
as the autoscaler (`aws-sdk-ecr`, `require: false` at load). Give that IAM
principal exactly:

```json
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage",
     "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload", "ecr:PutImage",
     "ecr:UploadLayerPart", "ecr:GetDownloadUrlForLayer"],
   "Resource": "arn:aws:ecr:<region>:<account>:repository/forge-ci-cache"}
]}
```

ECR repositories don't auto-create — make it once, with a lifecycle policy so
old cache layers don't accumulate forever:

```sh
aws ecr create-repository --repository-name forge-ci-cache
aws ecr put-lifecycle-policy --repository-name forge-ci-cache --lifecycle-policy-text \
  '{"rules":[{"rulePriority":1,"description":"expire cache images","selection":{"tagStatus":"any","countType":"sinceImagePushed","countUnit":"days","countNumber":30},"action":{"type":"expire"}}]}'
```

Any other registry (GHCR, Docker Hub, a local one): set
`FORGE_CI_BUILD_CACHE_REGISTRY_USERNAME` / `_PASSWORD` to a machine user with
push access to that one repository. Leave all three unset for an
unauthenticated registry. Fork pull requests never receive cache
credentials (they are refused the Docker socket anyway).

**Runner**: nothing to configure. The install command's `--allow-docker`
downloads a pinned buildx into `/opt/forge-ci-runner/bin/buildx` and sets
`BUILDX_BIN`; the runner copies it into job images that don't ship one.
Runners started some other way (a custom AMI boot script, for one) don't get
`BUILDX_BIN`: that only matters for job images without buildx (`cimg/*`
images include it), and setting `BUILDX_BIN` to a buildx binary fixes it.

**Pipeline**: ask for the cache on the job that builds images —

```yaml
jobs:
  deploy:
    docker: [{ image: cimg/ruby:3.3 }]
    resource_class: deploy
    steps:
      - checkout
      - setup_remote_docker:
          docker_layer_caching: true      # version: is accepted and ignored
      - run: forge-ci-build -t registry/app:$SHA .   # then push as usual
```

`forge-ci-build` is installed into the job container by the runner; it is
`docker buildx build` with the cache flags filled in (`--load` included
unless you pass `--push`/`--output`). Builds that manage their own buildx
invocation (Kamal, bake) use the environment instead. Kamal's default build
driver is already `docker-container`, so its registry cache works with the
ref forge-ci exports. Kamal puts its own `registry: server:` in front of
`builder: cache: image:`, so give it `FORGE_CI_BUILD_CACHE_IMAGE` (the ref
without the registry host), and keep the cache repository on the same
registry as the app image (for ECR: same account and region). In
`deploy.yml`:

```yaml
builder:
  cache:
    type: registry
    image: <%= ENV.fetch("FORGE_CI_BUILD_CACHE_IMAGE", "app-build-cache") %>
    options: mode=max
```

`FORGE_CI_BUILD_CACHE_IMAGE` is only set inside forge-ci jobs; the fallback
keeps `kamal deploy` from your laptop working (with its own cache image).

Every step sees `FORGE_CI_BUILD_CACHE_FROM` / `_TO` (the ref),
`FORGE_CI_BUILD_CACHE_IMAGE` (the ref without its registry host),
`FORGE_CI_BUILD_BUILDER` (a per-job buildx builder, already created) and the
login credentials. A job with `docker_layer_caching: true` on a server
without `FORGE_CI_BUILD_CACHE_REGISTRY` logs a warning and builds uncached.
