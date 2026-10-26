# forge-ci-runner (Go)

The opt-in **Docker runner** for ForgeCI on PR #28's `runner-go` branch,
rewritten from Ruby as a single static Go binary — no Ruby needed on Go
runner hosts. **Ruby remains the default.** The Ruby/Rails control plane
stays unchanged; switching runners alone needs no DB migration. Same daemon
loop and control-plane contract, with deliberate behavioral differences below:

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

For an existing host, follow the [Ruby-to-Go runner migration guide](../DEPLOY.md#ruby-to-go-runner-migration).
Use `--implementation go` (space-separated), first on an idle non-deploy
canary. The installer replaces the existing service, never starts both
implementations under one identity. It rewrites the env file and unit:
preserve **all original installer flags** and custom env settings, including
timeouts, Docker/buildx settings, and token-file configuration. Protect tokens
and backups; do not paste them into logs or commits. Reinstall rollback uses
`--implementation ruby` with the same settings. Exact rollback restores
`/opt/forge-ci-runner.old`, `/etc/forge-ci-runner.env.bak`, and
`/etc/systemd/system/forge-ci-runner.service.bak` together, then reloads systemd
and restarts the service; retain separate protected backups before another
install replaces those files. Failed activation attempts automatic restoration.

The client reports per-process presence on idle claims and job heartbeats.
Admins see status and current work in **Settings → Runners** after deploying
the web migration and restarting upgraded runners. See
[presence semantics](../docs/api.md#runner-presence); old servers ignore these headers.

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

Same configuration variables as the [Ruby runner](../runner/README.md#environment-variables):
`CONTROL_PLANE_URL`, `RUNNER_TOKEN`/`RUNNER_TOKEN_FILE`, `RESOURCE_CLASS`,
`POLL_INTERVAL`, `MAX_IDLE_INTERVAL`, `HEARTBEAT_INTERVAL`, `LOG_CHUNK_SIZE`,
`LOG_FLUSH_INTERVAL`, `CHECKOUT_REPO_URL`, `REDACT_MIN_LENGTH`, `DOCKER_BIN`,
`BUILDX_BIN`, `STEP_NO_OUTPUT_TIMEOUT` (600), `JOB_TIMEOUT` (3600),
`IDLE_SHUTDOWN_AFTER` + `IDLE_SHUTDOWN_COMMAND`, `ALLOW_DOCKER_SOCKET`,
`DOCKER_SOCKET_PATH`, `REQUEUE_ON_SHUTDOWN`.

## Deliberate differences from the Ruby runner

- **Process groups**: every subprocess gets its own; interruption is
  TERM-group → 5s grace → KILL-group. Interrupted foreground steps also
  immediately remove the primary container, stopping container-side descendants
  and detached background steps. Killing the `docker exec` client alone never
  stops those processes. Remaining steps, including `on_fail` and `always`, are
  logged as skipped (`job interrupted`); a timeout still fails the job with 124.
  Ruby also supports the 600s no-output timeout and 3600s job timeout (both
  disabled with `0`), but checks deadlines while streaming commands and kills
  the client, leaving container-side processes until cleanup. Go applies the
  job deadline across execution, including Docker setup and transfers, and
  stops container-side work immediately. Do not rely on timeout-triggered
  `on_fail`/`always` steps for cleanup; normal command failure still runs them.
- **Streaming redaction**: output is redacted at emission with a retained
  tail, so secrets split across read boundaries (or timer flushes) are still
  caught; valid UTF-8 is never split across chunks, invalid bytes become
  U+FFFD. (The Ruby runner redacted per read and could leak split secrets.)
- **Four separate lifetimes** (stop claiming / interrupt execution /
  heartbeats / final reporting) instead of one flag — see
  `internal/runner/runner.go`.
- Ordinary command failure semantics, key templates, workspace namespace,
  deferred-step warnings, and step naming match the Ruby runner; timeout
  handling is not fully interchangeable, as described above.

## Distribution

The root web-image `Dockerfile` cross-compiles `linux/amd64` + `linux/arm64`
and includes both binaries and `SHA256SUMS` in the served `/runner.tar.gz`
alongside the Ruby runner. The installer selects Go with `--implementation go`;
Ruby stays the default until the [soak/cutover gates](SOAK.md) pass. This branch
does not establish that PR #28 has merged, deployed, or completed its soak.
`runner-go/Dockerfile` builds a Go runner container; compose still selects the
Ruby runner until an explicit cutover.

### Source-only control-plane deployments

If deploying the Rails app from source rather than the root web image, build
the archive's Go artifacts from the **repository root** before installing Go
runners. Keep `runner/bin/forge-ci-runner` (the Ruby script) unchanged:

```sh
(cd runner-go && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o ../runner/bin/forge-ci-runner-linux-amd64 ./cmd/forge-ci-runner)
(cd runner-go && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o ../runner/bin/forge-ci-runner-linux-arm64 ./cmd/forge-ci-runner)
(cd runner/bin && sha256sum forge-ci-runner-linux-amd64 forge-ci-runner-linux-arm64 > SHA256SUMS)
```

On macOS, replace the last command with:

```sh
(cd runner/bin && shasum -a 256 forge-ci-runner-linux-amd64 forge-ci-runner-linux-arm64 > SHA256SUMS)
```

Set `FORGE_CI_RUNNER_PATH` on the control plane to this populated `runner/`
directory (absolute path). It controls the served archive, not the runner's
runtime settings. A Ruby-only source archive cannot satisfy `--implementation go`;
the installer aborts before replacing the old service if its binary is absent.
