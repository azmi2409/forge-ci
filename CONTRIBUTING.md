# Contributing to ForgeCI

Thanks for helping. ForgeCI is a small codebase with a few firm rules, and
this guide is all you need to get a change merged.

- [Ground rules](#ground-rules)
- [Repository layout](#repository-layout)
- [Set up](#set-up)
- [Run the tests](#run-the-tests)
- [Working on each part](#working-on-each-part)
- [Working on the web UI](#working-on-the-web-ui)
- [Database changes](#database-changes)
- [Pull requests](#pull-requests)
- [Where help is needed](#where-help-is-needed)

## Ground rules

- **Zero dependencies in the gem and the runner.** The `forge-ci` compiler
  gem and the runner use the Ruby standard library only. Adding a gem to
  either needs a discussion first. The control plane is a normal Rails 8 app,
  so regular gems are fine there.
- **Every change ships with tests, and all three suites stay green.** CI runs
  them on every pull request and every push to `main`.
- **CircleCI is the spec.** When forge-ci accepts a CircleCI feature, it
  should behave the way CircleCI documents it. When it doesn't support one,
  it should reject it with a clear error (or a warning, if ignoring it is
  harmless) rather than silently doing something different.
- **Secrets never leak.** Context values must not reach logs, API responses,
  the UI or pull requests from forks. Tests assert this; keep them passing
  and add to them when you touch secret handling.

## Repository layout

| Path | What |
|---|---|
| `lib/`, `exe/`, `test/` | The `forge-ci` gem: config compiler and CLI (stdlib only) |
| `web/` | Rails 8 control plane: API, GitHub App, web UI, background jobs |
| `runner/` | Docker runner daemon (stdlib only) |
| `skills/forge-ci/SKILL.md` | The agent skill (`forge-ci skill install`); keep it in step when config support or the CLI changes |
| `docs/` | Architecture, API, configuration, troubleshooting, README screenshots |
| `DEPLOY.md`, `TODO.md` | Production deployment guide, remaining work |

It's a monorepo: the web app loads the gem with `path: ".."`, so clone the
whole repository.

## Set up

You need Ruby 3.2.3 or newer for the control plane (3.0+ is enough for the
gem and the runner). Postgres is the supported production database, but local
development and tests run on SQLite.

```sh
git clone https://github.com/azmi2409/forge-ci
cd forge-ci/web
bin/setup                                                    # bundle install + db:prepare
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails db:seed
DATABASE_URL="sqlite3:db/development.sqlite3" bin/rails server
# → http://localhost:3000, sign in as admin / password
```

To run real jobs locally, start a runner in another shell (it needs Docker
Engine):

```sh
cd runner
CONTROL_PLANE_URL=http://localhost:3000 RUNNER_TOKEN=<token printed by db:seed> bin/forge-ci-runner
```

## Run the tests

```sh
rake test                                                   # compiler gem
cd web && DATABASE_URL="sqlite3:db/test.sqlite3" bin/rails test   # control plane
cd runner && rake test                                      # runner
```

The runner's Docker integration test skips itself when no Docker daemon is
available. The Postgres-only claim path (`FOR UPDATE SKIP LOCKED`) is guarded
by adapter checks and has adapter-aware tests, so SQLite is enough locally.

## Working on each part

**Compiler (`lib/forge_ci/`).** Compilation is a pure function: parse →
validate → expand → interpolate → DAG → IR. Validation belongs in
`validator.rb` and returns errors (with line numbers where possible) instead
of raising. Anything that changes what runs is an error; anything
informational is a warning in `ir[:meta][:warnings]`. New IR fields must be
additive so older control planes and runners keep working.

**Control plane (`web/`).** The runner-facing contract (claim payload,
heartbeats, logs, cache) is documented in [docs/api.md](docs/api.md). Keep
changes to it additive, update that document in the same PR, and add a
controller test for the payload shape.

**Runner (`runner/`).** The runner shells out to the Docker CLI with argv
arrays, never through a shell string. `RecordingExecutor` in
`runner/test/test_helper.rb` records the Docker commands instead of running
them, so most behaviour can be tested without Docker. The `circleci` helper
installed into job containers lives in
`runner/lib/forge_ci_runner/circleci_cli.sh`; test it with real files (see
its existing tests) as well as unit tests.

**Configuration.** Every new environment variable goes in
[docs/configuration.md](docs/configuration.md), and in `.env.example` or
`DEPLOY.md` if operators need to set it.

## Working on the web UI

The UI is server-rendered ERB with no asset pipeline and no JavaScript
framework. It follows the **Kilat.host design conventions**: monochrome ink on
canvas, 1px hairlines for structure, colour only for state.

- **Design system:** `web/app/views/layouts/_design.html.erb` holds the tokens
  (`--canvas`, `--surface`, `--ink`, `--muted`, `--subtle`, `--line`,
  `--line-strong`, `--accent-soft`, the `danger`/`warn`/`ok` text colours and
  the three status colours) and the shared components: `button-primary`,
  `button-secondary`, `button-ghost`, `button-danger`, `card` with
  `card-header`/`card-body`/`card-footer`, `data-table`, `stat-strip`,
  `status-badge`, `chip`, `field`, `flash-success`/`flash-error`,
  `empty-state` and `code-block`. Use those classes and tokens; never put a
  hex colour in a view.
- **Colour rules:** there is no brand hue. The primary button, focus ring and
  selection are `--ink`. Hover on a bordered element is `--line-strong`, not a
  shadow; shadows are only for floating layers such as menus. Status is a dot
  before a word (`status_badge`), never colour alone.
- **Themes:** light is the default; dark is `[data-theme="dark"]` on `<html>`,
  set from the viewer's choice (light, dark or system) by the script in the
  design partial. Style through the tokens and both themes work.
- **Type:** Geist for text and Geist Mono for code, eyebrows, captions and
  numbers that line up, from Google Fonts. Dashboard headings are sentence
  case without a period (`page-heading`, `card-title`); landing-page headings
  end with a period and dim their second clause.
- **Layout:** signed-in pages use the shell in `layouts/application.html.erb`
  (240px sidebar from 1024px, a drawer below it, a 56px topbar with
  breadcrumbs). Set breadcrumbs with
  `content_for(:breadcrumbs) { breadcrumbs(["Overview", projects_path], ["acme/web"]) }`.
- **Page styles:** styles used by one page go in a `content_for(:head)`
  block at the top of that view, not inline `style=` attributes.
- **Icons:** `icon("name")` in `web/app/helpers/ui_helper.rb` renders an
  inline SVG on a 24px grid with a 1.7px stroke. Add new icons there in the
  same style.
- **Helpers:** time and duration formatting (`time_ago_tag`,
  `duration_text`), status badges (`status_badge`, `group_status`) and
  commit links live in the helpers. Reuse them so every page reads the same.
- **Check your change in a browser,** in both themes and at phone width
  (390px), with no horizontal scrolling. Playwright with the preinstalled
  Chromium works well for screenshots.
- **README screenshots** in `docs/images/` use sample data with neutral names
  (`acme/*`). Never use real projects or private repositories.
- **Accessibility:** use real buttons and links, label icon-only controls,
  keep body text at 4.5:1 contrast in both themes (`--subtle` is for
  placeholders and labels only), and respect `prefers-reduced-motion`.

## Database changes

- Add a migration under `web/db/migrate/` and commit the regenerated
  `web/db/schema.rb`. Keep the schema diff limited to your change.
- Migrations must work on Postgres and SQLite, and must be safe for existing
  data (defaults for new `NOT NULL` columns, for example).
- **Don't commit `web/db/test.sqlite3*` files.** Some are tracked, and
  running the tests modifies them. Check `git status` before committing, and
  restore them with `git checkout -- web/db/test.sqlite3_0 web/db/test.sqlite3_1`.

## Pull requests

- Open pull requests against `main`. Automated agents are welcome too; a
  human reviews and merges.
- Keep each pull request focused, ideally on one component.
- Describe what changed and why, and how you tested it. For UI changes,
  include before-and-after screenshots.
- Update the docs the change affects in the same pull request: the README's
  compatibility table, `docs/`, `DEPLOY.md` or `TODO.md`.
- All three test suites must pass in CI before merging.

## Where help is needed

[TODO.md](TODO.md) lists the remaining work in priority order: launch
blockers, then hardening, then the feature backlog. Its known-limitations
section lists the trade-offs accepted for v1; if you disagree with one,
challenge it with a pull request.

By contributing, you agree that your contributions are licensed under the
[MIT License](MIT-LICENSE).
