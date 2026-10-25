# forge-ci-runner (Go)

The **Docker runner** for ForgeCI, rewritten from Ruby as a single static Go
binary — no Ruby on runner hosts. Same daemon loop, same control-plane
contract, same behavior:

```
poll claim → start → execute → complete
   │                      │
   │                      ├─ heartbeat every 15s while running
   │                      └─ stream redacted log chunks (seq-numbered)
   └─ 422 (nothing claimable) → idle backoff 5s → 10s → … → 60s cap
```

Per claimed job the runner pulls the executor's images, creates an isolated
Docker network, starts service containers then a long-lived primary
container, and runs each step in it via `docker exec` (checkout, run, cache,
artifacts, workspaces, setup_remote_docker with registry-backed layer
caching). Containers and network are always cleaned up, under a bounded
context. Full behavior and the frozen wire contract: [CONTRACT.md](CONTRACT.md).
Test-coverage mapping from the Ruby suite: [TESTING.md](TESTING.md).

**Host target: Linux** (process groups, `sha256sum`, system `tar`). darwin
builds exist for tests and local development only.

## Build & test

```sh
go test -race ./...          # the whole suite; Docker-gated tests skip without a daemon
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o forge-ci-runner ./cmd/forge-ci-runner
./forge-ci-runner -version
```

Zero external dependencies (stdlib only). The two shell helpers
(`circleci_cli.sh`, `docker_build_wrapper.sh`) are embedded via `go:embed`
from `internal/executor/scripts/` — they are byte-identical copies of the
canonical `runner/lib/forge_ci_runner/*.sh` during the transition, enforced
by `TestEmbeddedHelpersMatchCanonical`. Re-copy; never fork.

## Run

```sh
CONTROL_PLANE_URL="https://ci.example.com" \
RUNNER_TOKEN="<token from Settings → Runners>" \
RESOURCE_CLASS="medium" \
  ./forge-ci-runner
```

Fails fast (exit 2) when the config is incomplete or `docker info` fails.

### Environment variables

Identical to the Ruby runner (`runner/README.md` has the full table):
`CONTROL_PLANE_URL`, `RUNNER_TOKEN`/`RUNNER_TOKEN_FILE`, `RESOURCE_CLASS`,
`POLL_INTERVAL`, `MAX_IDLE_INTERVAL`, `HEARTBEAT_INTERVAL`, `LOG_CHUNK_SIZE`,
`LOG_FLUSH_INTERVAL`, `CHECKOUT_REPO_URL`, `REDACT_MIN_LENGTH`, `DOCKER_BIN`,
`BUILDX_BIN`, `STEP_NO_OUTPUT_TIMEOUT` (600), `JOB_TIMEOUT` (3600),
`IDLE_SHUTDOWN_AFTER` + `IDLE_SHUTDOWN_COMMAND`, `ALLOW_DOCKER_SOCKET`,
`DOCKER_SOCKET_PATH`, `REQUEUE_ON_SHUTDOWN`.

## Deliberate differences from the Ruby runner

- **Process groups**: every subprocess gets its own; interruption is
  TERM-group → 5s grace → KILL-group, and job-level interruption also
  explicitly removes the job containers (killing the `docker exec` client
  alone never stops container-side processes).
- **Streaming redaction**: output is redacted at emission with a retained
  tail, so secrets split across read boundaries (or timer flushes) are still
  caught; valid UTF-8 is never split across chunks, invalid bytes become
  U+FFFD. (The Ruby runner redacted per read and could leak split secrets.)
- **Four separate lifetimes** (stop claiming / interrupt execution /
  heartbeats / final reporting) instead of one flag — see
  `internal/runner/runner.go`.
- Everything else — exit codes (124 timeout, 130 cancel), `when` semantics,
  key templates, workspace namespace, deferred-step warnings, step naming —
  matches the Ruby runner exactly.

## Distribution

The web image cross-compiles `linux/amd64` + `linux/arm64` and ships the
binaries in `/runner.tar.gz` next to the Ruby runner; the install script
picks one with `--implementation=go` (Ruby remains the default until the
cutover gates pass — see the plan's Phase 8). `Dockerfile` here builds the
containerized runner used by docker-compose at cutover.
