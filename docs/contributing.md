# Contributing

## Ground rules

- **Zero-dependency philosophy** for the `forge-ci` gem and the runner:
  Ruby stdlib only. No exceptions without discussion.
- The control plane is a standard Rails 8 app — normal gems are fine there.
- **Every change ships with tests**, and the suite stays green:
  `rake test` (gem), `bin/rails test` (web), `rake test` (runner).
- CI runs all three suites on every push to `main` and every PR.

## Dev setup

The repo is a monorepo — clone it whole (the web app consumes the gem via
`path: ".."`, which only resolves in this layout):

```sh
git clone https://github.com/azmi2409/forge-ci
cd forge-ci
```

**Compiler gem** (Ruby ≥ 3.0, no Docker, no DB):

```sh
rake test   # minitest, fixtures in test/fixtures/
```

**Control plane** (Ruby 3.2.3):

```sh
cd web
bin/setup                                        # bundle install + db:prepare
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails db:seed
DATABASE_URL="sqlite3:db/test.sqlite3" bin/rails test
```

No Postgres locally? The SQLite fallback exists for exactly this. The
Postgres-only paths (`SKIP LOCKED`) are adapter-guarded and covered by
adapter-aware tests.

**Runner** (Ruby ≥ 3.0, Docker Engine for the integration test):

```sh
cd runner
rake test   # the Docker-gated test skips gracefully without a daemon
```

## How work gets in

- **PRs against `main`** — automated agents included. CI must be green;
  a human reviews and merges.
- Keep PRs focused: one component per PR where possible.
- Update the relevant README/docs when you change behavior, env vars, or the
  API contract. Docs live in `docs/`; component READMEs link to them.

## What needs help

See [TODO.md](../TODO.md) — launch blockers first, then hardening, then the
feature backlog. The known-limitations section lists accepted v1 trade-offs;
challenge them with a PR if you disagree.
