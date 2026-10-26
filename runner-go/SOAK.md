# Soak & cutover gates (Go runner)

The cutover gate is **a week-long soak AND every scenario below green** —
not elapsed time alone. This is a checklist, not evidence of a completed soak,
merge, or deployment of PR #28. Ruby remains the default; `--implementation go`
is opt-in. The root web image packages both implementations; source-only
deployments must [build the binaries and checksum manifest](README.md#source-only-control-plane-deployments).
Use the [migration runbook](../DEPLOY.md#ruby-to-go-runner-migration) for
operator commands, environment preservation, and rollback. Rails remains Ruby;
switching only the runner does not require a DB migration.

## Stage sequence (reversible at every step)

1. **Ship both.** Branch packaging supports both; verify the deployed archive
   actually contains the binaries and `SHA256SUMS`. Installer default stays Ruby.
2. **Opt-in Go.** Use `--implementation go` on an idle, non-deploy staging
   canary. Never run both implementations under one runner identity; retain
   fork/trusted host isolation and existing resource-class routing.
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
- timeout behavior: both return 124, but Go removes the primary container
  immediately and skips all remaining steps, including `on_fail`/`always`;
  normal command failure still runs failure handlers. Check jobs do not rely
  on timeout-triggered handlers; see [behavioral differences](README.md#deliberate-differences-from-the-ruby-runner).

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
- [ ] Upgrade preserves every original installer flag (`--class`,
      `--idle-shutdown`, `--asg`, `--allow-docker`, `--requeue-on-shutdown`)
      and securely reapplies all custom env settings after installer rewrite;
      token-file settings, timeouts, and Docker/buildx settings are not lost
- [ ] Protected independent backups of env, unit, and tree survive later
      installs overwriting `.old`/`.bak`; no tokens appear in logs or commits
- [ ] Failed download (including buildx) leaves the old runner running
- [ ] Failed activation restores the previous tree, unit, env, and running service
- [ ] Installer reports success only after `systemctl is-active` succeeds
- [ ] Rollback reinstall with `--implementation ruby` and original settings,
      or restoration of the matching `.old` tree plus env/unit `.bak` files,
      restores the single service (daemon-reload, restart, verify active)
- [ ] Unsupported architecture rejected before anything is touched
- [ ] Compose image (Go runner container) drives the host daemon end to end

## Cutover

Only after recorded evidence satisfies every gate, including a full week of
staging + production Spot-class traffic: consider flipping the installer
default (stage 4), watch a week, then remove Ruby (stage 5). These are future
gates, not completed rollout claims. Before stage 5, reinstall rollback uses
`--implementation ruby` with **all original flags and custom settings**:
the installer rewrites env/unit files rather than merging them.

Successful upgrades retain the previous installation at `/opt/forge-ci-runner.old`,
with backups at `/etc/forge-ci-runner.env.bak` and
`/etc/systemd/system/forge-ci-runner.service.bak`. Restore all three together
for exact rollback, reload systemd, and restart the service; follow the
[migration runbook](../DEPLOY.md#ruby-to-go-runner-migration). Later installs
replace these backups, so keep independent protected copies. Failed activation
automatically attempts restoration and restarts the old service only if it
was running before the upgrade; inspect its status instead of assuming success.
