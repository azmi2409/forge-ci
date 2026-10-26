# Changelog

Versions of the `forge-ci` gem (the compiler and CLI). The control plane and
runner are deployed from this repository's `main` and aren't versioned
separately.

## Unreleased

- The Docker runner is now also available as a **static Go binary** (stdlib
  only, no Ruby on runner hosts). The web image cross-compiles
  `linux/amd64` + `linux/arm64` and ships the binaries in `/runner.tar.gz`
  next to the Ruby runner; the install command accepts `--implementation=go`
  (Ruby stays the default until the soak gates pass). The installer verifies
  the binary's SHA256, installs atomically, keeps the previous binary for
  rollback, and never runs both implementations under the same runner
  identity. The Go runner keeps the exact control-plane contract and
  behavior, with deliberate hardening: secrets split across streamed
  log-read boundaries are still redacted (retained-tail emission), log
  chunks post strictly in seq order with bounded queueing, every subprocess
  gets its own process group (TERM → grace → KILL) and job-level
  interruption explicitly removes containers, and shutdown separates four
  lifetimes (stop claiming / interrupt execution / heartbeats / final
  reporting). Runner contract, fixtures, and test-coverage matrix:
  `runner-go/CONTRACT.md`, `runner-go/TESTING.md`.
- Fix Go runner shutdown signal handling during active jobs and propagate
  cancellation through setup and transfers. Preserve image working directories
  when jobs omit an override. Serialize log delivery, synchronize output
  activity tracking, and preserve UTF-8 across reads. Runner upgrades stage
  dependencies before stopping and restore the previous installation on failure.
- Make concurrent runner archive downloads safe with unique staging files.
  Preserve overlapping secrets across log reads, isolate service container
  names per job, and stop container-side work after interrupted steps. Fix
  lifecycle CI synchronization and cancellation during the final step.
  Interrupted steps remove the primary container before returning; remaining
  steps, including `on_fail`/`always`, are skipped because that container is
  no longer safe to reuse. Redact step and service environment secrets too.
- Document Ruby-to-Go runner migration, configuration preservation, canary
  validation and rollback across deployment, architecture, contributor and
  agent guidance. Ruby remains the installer default pending soak gates.
- `forge-ci login [--url URL]` / `forge-ci logout`: OAuth sign-in for the
  CLI. The browser opens at the server, you sign in with your web-UI
  account, and the token (authorization-code + PKCE, stored per server in
  `~/.config/forge-ci/credentials.json`, 0600) is picked up automatically by
  `trigger`/`cancel` — `--token` and `FORGE_CI_ADMIN_TOKEN` still win.
  `--manual` trades the browser for a pasted code over SSH. Sessions refresh
  automatically and act as the signed-in user (members view/cancel, admins
  trigger). Server side this is Doorkeeper (`/oauth/*`), plus a new
  `GET /api/v1/me`; the JSON API now accepts personal OAuth tokens next to
  the shared admin token.
- Harden OAuth callbacks: validate error state and callback path, escape
  browser output, and enforce the callback deadline for incomplete requests.
  Reject invalid callback ports and malformed server URLs/responses.
- Save credentials atomically without overwriting malformed files. Logout
  revokes refresh tokens even after access-token expiry; API use of a refreshed
  access token invalidates its previous refresh token.
- Separate fork and trusted runner pools with immutable `fork_only` tokens.
  Existing/shared tokens remain trusted-only; admins provision dedicated fork
  runners in Settings. Fork jobs cannot receive project/context secrets,
  including direct intake and legacy job snapshots.
- Encrypt persisted job context snapshots and migrate existing plaintext
  values. Back up encryption keys and stop web/worker writers during upgrade.
- Update bundled agent skill for OAuth login, exclusive fork runner pools,
  isolated caches/checkout credentials, and safe infrastructure retries.

## 0.3.0 (2026-10-24)

- `setup_remote_docker` takes `docker_layer_caching: true`: the compiler
  passes it to the IR (`layer_caching: true`) and rejects non-boolean values.
  With `FORGE_CI_BUILD_CACHE_REGISTRY` on the server, such jobs get a
  registry-backed layer cache (`forge-ci-build`, or Kamal via
  `FORGE_CI_BUILD_CACHE_IMAGE`).
- `gem install forge-ci` is the documented install; `rake build`,
  `rake install` and `rake release` work from a checkout.
- Gemspec metadata: source and changelog links, MFA required to publish.
- The bundled agent skill installs the CLI with `gem install forge-ci`, and
  covers `docker_layer_caching`.

## 0.2.0 (2026-10-22)

- `forge-ci trigger` (start a pipeline through the admin API, `--wait` for
  the result) and `forge-ci cancel`.
- `forge-ci skill install` / `forge-ci skill show`: the bundled agent skill
  ships in the gem.
- `parallelism:` reaches the IR (with `circleci tests` splitting in the
  runner).
- The compiler accepts `setup_remote_docker`, bare or with options.

## 0.1.0

- First release: `forge-ci validate` and `forge-ci compile`, compiling
  CircleCI 2.1 configs (executors, commands, parameters, workflows,
  `requires`, `matrix`, branch filters, caches, workspaces, artifacts) into
  ForgeCI's IR.
