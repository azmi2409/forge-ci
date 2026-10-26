# Soak & cutover gates (Go runner)

The cutover gate is **a week-long soak AND every scenario below green** —
not elapsed time alone. Baseline for everything: the control plane's
`/runner.tar.gz` carries both implementations; the installer defaults to
Ruby; `--implementation=go` is opt-in.

## Stage sequence (reversible at every step)

1. **Ship both.** Web image builds both; installer default stays Ruby.
   (Done — root `Dockerfile`, `RunnerInstallController`, installer.)
2. **Opt-in Go.** `--implementation=go` on a non-deploy class in staging.
3. **Comparison soak.** Ruby and Go runners side by side on staging with the
   same pipeline set.
4. **Default flip.** After the gates, the installer's default becomes Go
   (one-line change in `script.text.erb`).
5. **Removal.** After the rollback window closes: delete Ruby `runner/`,
   rename `runner-go/ → runner/`, flip the compose runner context, update
   docs.

## Functional soak matrix (staging, both implementations)

- `run` steps: success, failure, `when: on_fail / always`, background steps
- `checkout` with and without a GitHub App token (private + public repos)
- caches: save, restore hit, clean miss, checksum keys, fork/trusted
  isolation (server-side `fork_only` namespaces)
- artifacts: single files, directories, destinations
- workspaces: persist → attach across jobs in one workflow
- parallelism (node index/total, `circleci tests split`)
- `setup_remote_docker` with and without `docker_layer_caching` (layer cache
  on a real registry)
- log tailing on the job page while a job runs (flush interval)
- redaction: env secrets, checkout token, build-cache password

## Lifecycle gates (Go runner must pass all)

- [ ] `go test -race ./...` green on a native Linux CI host
- [ ] `CGO_ENABLED=0` binaries for linux/amd64 + linux/arm64 run **without
      Ruby** on a clean host (fresh install through the installer)
- [ ] Docker integration job green in CI (required, not universally skipped)
- [ ] Real Rails/PostgreSQL contract smoke: the Go client claims, runs and
      completes a job against a live control plane (not just httptest)
- [ ] Streaming: newline-free output, secrets split across read boundaries,
      UTF-8 chunk boundaries, slow log endpoint (backpressure, no memory
      growth)
- [ ] TERM during: claim, pull, step, upload, cleanup, final reporting —
      every path terminates cleanly and reports/releases correctly
- [ ] No leaked processes, containers, networks, buildkit builders, or temp
      files after repeated jobs (timeout, cancel, and requeue paths)
- [ ] Security regression: fork/trusted pool exclusivity, cache isolation,
      anonymous fork checkout, privileged-checkout refusal for forks

## Installer gates

- [ ] Fresh install (apt path) with `--implementation go`
- [ ] Fresh install (dnf/yum path) with `--implementation go`
- [ ] Upgrade over an existing Ruby runner (single service; previous tree
      retained at `/opt/forge-ci-runner.old`)
- [ ] Failed download (including buildx) leaves the old runner running
- [ ] Failed activation restores the previous tree, unit, env, and running service
- [ ] Installer reports success only after `systemctl is-active` succeeds
- [ ] Rollback: `--implementation ruby` reinstall restores service
- [ ] Unsupported architecture rejected before anything is touched
- [ ] Compose image (Go runner container) drives the host daemon end to end

## Cutover

When every box is ticked for a full week of staging + production Spot-class
traffic: flip the installer default (stage 4), watch a week, then remove the
Ruby runner (stage 5). Before stage 5, rollback is a reinstall with
`--implementation ruby`. Successful
upgrades retain the previous installation at `/opt/forge-ci-runner.old`, with
configuration backups at `/etc/forge-ci-runner.env.bak` and
`/etc/systemd/system/forge-ci-runner.service.bak`. Failed activation automatically
restores the previous installation and configuration and restarts it if it was
running before the upgrade.
