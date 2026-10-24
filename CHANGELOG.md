# Changelog

Versions of the `forge-ci` gem (the compiler and CLI). The control plane and
runner are deployed from this repository's `main` and aren't versioned
separately.

## Unreleased

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
