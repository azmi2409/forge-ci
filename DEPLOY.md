# Deploying ForgeCI

Three steps: start the server, connect GitHub, add a runner. Nothing needs
generating by hand; secrets are created on first boot.

```
GitHub ──webhooks──▶ ForgeCI (web UI, API, jobs) ◀──polls over HTTPS── runners (Docker)
                     Postgres + a data volume
```

Runners only make outbound HTTPS requests, so they need no open ports.

## 1. Start the server

On any host with Docker and a public HTTPS URL (GitHub webhooks need one):

```sh
git clone https://github.com/azmi2409/forge-ci && cd forge-ci
echo "APP_HOST=https://ci.example.com" > .env
echo "FORCE_SSL=true" >> .env        # when a proxy in front serves HTTPS
docker compose up -d --wait   # waits until ForgeCI is ready (first boot: a minute or two)
docker compose exec web bin/rails forge_ci:reset_admin   # prints the admin password
```

This starts Postgres, the ForgeCI web container on port 3000 (`WEB_PORT`
changes it) and its background `worker` container. Put your HTTPS proxy (Caddy, nginx, Cloudflare Tunnel) in front.

**Coolify:** create a Docker Compose resource from this repository, set
`APP_HOST` (and `FORCE_SSL=true`) in its environment, and give the `web`
service your domain.

On first boot ForgeCI:
- creates its databases;
- generates its secrets into the `forge-ci-data` volume (`secrets.yml`);
- creates an `admin` user and prints its password in the `web` logs.

`bin/rails forge_ci:reset_admin`, run in the `web` container, prints a new
password for that admin at any time. Use it if you missed the logs or the
database already had users. On Coolify, run it from the `web` service's
**Terminal** tab. Sign in with the username and password it prints, then change the password under
**Account**.

## 2. Connect GitHub

Open **Settings**, choose who owns your repositories (an organization, by
name, or your personal account) and click **Connect GitHub**. GitHub creates a
private ForgeCI App with the right permissions and webhook and sends you
back. Then click **Install on repositories** and pick the repositories.

A private App can only be installed on the account that owns it, so create it
on the account that owns your repositories. To create an App for an
organization you must be one of its owners. If you connected the wrong account, open
**Use a different account** under Settings to create a new App for the right
one, then delete the old App on GitHub (its **Advanced** settings).

Each repository's first push creates its project. Pipelines run on push and
pull request, and results come back as a `forge-ci` commit status. Private
repositories need nothing extra.

## 3. Add runners

**Settings → Runners** shows a one-line install command. Pick a resource
class if you want one, then paste the command on each runner machine (Ubuntu,
Debian, Amazon Linux or Fedora with systemd):

```sh
curl -fsSL https://ci.example.com/install-runner | sudo sh -s -- --token <token> --class spot
```

The default installs Docker and the Ruby runner (packages skipped when already
present), downloads the runner from your server, and starts the
`forge-ci-runner` service. The static Go runner is opt-in with
`--implementation go`; it needs Docker but no Ruby on runner hosts. Both use
the same Rails control plane. Watch `journalctl -u forge-ci-runner -f`.

A runner claims jobs whose `resource_class` matches its `--class`, plus jobs
with no class. A runner installed without `--class` claims any job.
For example, run checks on Spot machines (`--class spot`) and deploys on an
on-demand machine (`--class deploy`).

When AWS reclaims a Spot machine mid-job, the job is canceled by default. If
every job on that class is safe to run twice (tests, not deploys), add
`--requeue-on-shutdown` to its install command and the job goes back to the
queue for another runner instead (at most twice):

```sh
curl -fsSL https://ci.example.com/install-runner | sudo sh -s -- --token <token> --class spot --requeue-on-shutdown
```

Never use it on deploy runners: a deploy cut off halfway must not run again
by itself.

### Ruby-to-Go runner migration

This switches the Docker runner, not the Rails control plane or compiler.
First deploy a web image containing the Go runner changes: `/runner.tar.gz`
must include `bin/forge-ci-runner-linux-amd64`,
`bin/forge-ci-runner-linux-arm64`, and `bin/SHA256SUMS`. Source-only control
planes must build and stage those artifacts first; see
[`runner-go/README.md`](runner-go/README.md). No database migration or pipeline
YAML change is required solely for switching runner implementation.

1. **Canary one non-deploy Linux host** (x86_64 or arm64). Pause incoming
   work for its pool and wait for all active jobs to finish. Verify the host
   is idle before installation: the installer stops its service, so do not
   upgrade during a deployment. Keep Ruby installed for rollback.
2. **Back up config and record flags.** Inspect the environment locally;
   never paste tokens or secrets into logs, tickets, or shell history.

   ```sh
   sudo cp -p /etc/forge-ci-runner.env /etc/forge-ci-runner.env.pre-go
   sudo cp -p /etc/systemd/system/forge-ci-runner.service \
     /etc/systemd/system/forge-ci-runner.service.pre-go
   curl -fsSL https://ci.example.com/install-runner -o /tmp/install-forge-ci.sh
   ```

3. **Install explicitly.** Use the existing token, class, and original flags
   from Settings. Substitute securely; command-line tokens can be visible to
   local process inspection. The example below is not a literal token.

   ```sh
   sudo sh /tmp/install-forge-ci.sh --implementation go \
     --token '<existing-runner-token>' --class spot --requeue-on-shutdown
   ```

   Preserve `--idle-shutdown SECONDS --asg` for scale-to-zero hosts and
   `--allow-docker` only for trusted Docker-enabled hosts. Use
   `--requeue-on-shutdown` only for retry-safe jobs, never deploys. Keep the
   same trusted/fork-only token pool; implementation does not change trust.

4. **Restore custom environment before resuming work.** Installer regenerates
   `/etc/forge-ci-runner.env`; it does not merge custom settings. While work
   remains paused, stop the service and restore settings such as
   `JOB_TIMEOUT`, `RUNNER_TOKEN_FILE`, polling intervals, or repository
   overrides from the protected backup. Retain generated `BUILDX_BIN` if
   applicable. If using `RUNNER_TOKEN_FILE`, remove generated `RUNNER_TOKEN`
   so it cannot take precedence. Restart after editing.

   ```sh
   sudo systemctl stop forge-ci-runner
   sudoedit /etc/forge-ci-runner.env
   sudo systemctl start forge-ci-runner
   /opt/forge-ci-runner/bin/forge-ci-runner --version
   sudo systemctl is-active forge-ci-runner
   sudo systemctl cat forge-ci-runner
   sudo journalctl -u forge-ci-runner -n 100 --no-pager
   ```

   `ExecStart` must run the binary directly, without `ruby`. Run non-deploy
   canaries covering checkout, logs, caches, artifacts, workspaces,
   cancellation, and retry-safe shutdown. Interrupted Go steps remove the
   primary container; later steps, including `on_fail`/`always`, are skipped.
   Normal command failures still honor those conditions.

5. **Rollback if necessary.** Pause work and drain again, then reinstall with
   `--implementation ruby`, the same token/class/flags, and restore custom
   environment settings before resuming. Automatic rollback handles failed
   activation, not failures discovered later in real jobs. Successful upgrades
   retain `/opt/forge-ci-runner.old`, `/etc/forge-ci-runner.env.bak`, and
   `/etc/systemd/system/forge-ci-runner.service.bak`; subsequent installs
   replace those backups, so keep the separate `.pre-go` copies.

   Alternatively, restore the matching tree, environment and unit together
   without downloading anything. Verify `.old` is the desired Ruby install
   and both `.bak` files belong to that upgrade before running this. Pause
   work and drain first; keep any failed Go tree for diagnosis:

   ```sh
   set -e
   sudo test -d /opt/forge-ci-runner.old
   sudo test -f /etc/forge-ci-runner.env.bak
   sudo test -f /etc/systemd/system/forge-ci-runner.service.bak
   sudo test ! -e /opt/forge-ci-runner.failed-go
   sudo systemctl stop forge-ci-runner
   sudo mv /opt/forge-ci-runner /opt/forge-ci-runner.failed-go
   sudo mv /opt/forge-ci-runner.old /opt/forge-ci-runner
   sudo cp -p /etc/forge-ci-runner.env.bak /etc/forge-ci-runner.env
   sudo cp -p /etc/systemd/system/forge-ci-runner.service.bak \
     /etc/systemd/system/forge-ci-runner.service
   sudo systemctl daemon-reload
   sudo systemctl start forge-ci-runner
   sudo systemctl is-active forge-ci-runner
   ```

   Stop on any failed command. This restores configuration as it was saved,
   unlike reinstalling with defaults. Verify a canary before resuming work.

Do not run Ruby and Go simultaneously with the same runner identity. Existing
Compose runners and AWS user-data remain Ruby during this opt-in phase;
changing installer does not migrate existing hosts or future ASG instances
automatically. Roll out launch templates separately after canary acceptance.
The default remains Ruby until the week-long soak **and** every gate in
[`runner-go/SOAK.md`](runner-go/SOAK.md) pass; CI alone is not cutover approval.

### Isolate fork pull requests

Run fork pull requests on dedicated, disposable runner hosts with no deploy
credentials, host Docker socket access, or access to privileged internal
services. Resource classes alone are not a security boundary: fork config
can choose a class or omit it.

Runner tokens default to trusted repository jobs only. Provision a dedicated
fork-only token in **Settings → Runners** for an isolated fork runner.
Fork-only tokens never claim trusted jobs; ordinary tokens never claim fork
jobs, even when resource classes match. Fork jobs receive neither project
variables nor context secrets. Without a fork-only runner, fork jobs remain
queued rather than falling back to a privileged host.
Fork caches are separate from trusted caches. Fork checkout is anonymous and
never receives a GitHub App installation token or an operator-configured
repository URL. Private fork checkout cannot use privileged credentials and
will fail unless its GitHub repository is anonymously accessible.

Do not reuse a host that ran untrusted jobs for deployments. Rebuild it first.

### Or run jobs on the server itself

For a single machine, skip the install command: add `RUNNERS=1` to `.env`
(or Coolify's environment) and run `docker compose up -d` again. Each runner
container uses the server's Docker socket and the generated token, so there
is nothing else to configure. `RUNNERS=2` runs two jobs at a time, and
`RUNNER_RESOURCE_CLASS=spot` limits them to one class.

Jobs then run on the server next to ForgeCI, and through the socket their
commands have root on it. Use this for repositories you trust, and give the
host enough CPU and memory for your jobs. You can still add separate runner
machines alongside it.

### Secrets for your jobs

Open a project (it appears after its first push) and add them under
**Environment variables**. Every job in the project gets them, except jobs
from fork pull requests. Values are encrypted, masked in logs, and can't be
read back from the dashboard. A job's own `environment:` in the config wins on a clash.

That's it. Push a commit to an installed repository and watch it on the
Projects page.

---

## Optional

### Your own Postgres

Point `DATABASE_URL` at any Postgres 14+ whose role can create databases.
ForgeCI also creates `<name>_queue` and `<name>_cache` next to it. To use
databases you created yourself, set `QUEUE_DATABASE_URL` and
`CACHE_DATABASE_URL`. Each must be a separate database.

### S3 for logs and artifacts

Logs, artifacts and caches are kept on the `forge-ci-data` volume by default.
To keep them in S3 (or MinIO) instead, create the bucket and set:

```
ACTIVE_STORAGE_SERVICE=amazon
AWS_S3_BUCKET=forge-ci
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

### Setting secrets yourself

Any generated secret can be overridden by its environment variable, for
example to share one value across servers:
- `SECRET_KEY_BASE`;
- the three `ACTIVE_RECORD_ENCRYPTION_*` keys;
- `FORGE_CI_ADMIN_TOKEN`;
- `FORGE_CI_RUNNER_TOKEN`.

Likewise:
- `FORGE_CI_UI_USER` and `FORGE_CI_UI_PASSWORD` choose the first admin;
- `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` and `GITHUB_WEBHOOK_SECRET`
  replace Connect GitHub with an App you registered yourself.

Every variable is listed in [docs/configuration.md](docs/configuration.md).

### Upgrade job context encryption

The job-context migration encrypts existing snapshots using the same
`ACTIVE_RECORD_ENCRYPTION_*` keys as contexts. Keep those keys unchanged.

1. Back up the database and the `forge-ci-data` volume containing `secrets.yml`
   (or securely back up the configured encryption keys).
2. Pause runner services and stop web/worker processes so no old process reads
   or writes job rows during the schema cutover.
3. Run `bin/rails db:migrate` with the new release and the existing encryption
   keys. Do not start the old release against the migrated schema.
4. Start the new web/worker processes, then runners. Verify a trusted job can
   still read its context and fork jobs only run on dedicated fork runners.

Old backups, database WAL, and replicas may still contain historical plaintext.
Handle them as secrets under your retention policy; encryption migration does
not erase historical copies. Restore requires the matching encryption keys.

### Use it without the GitHub App

Sign the CLI in with your web-UI account — it opens a browser, you log in,
done:

```sh
forge-ci login --url https://ci.example.com

# Start a pipeline for the current branch and commit; --wait exits non-zero on failure.
forge-ci trigger .circleci/config.yml --project myapp --wait
```

The session is stored per server in `~/.config/forge-ci/credentials.json`
(0600), refreshed automatically, and acts as your user: members can view and
cancel pipelines, admins can also trigger them, create projects and rotate
contexts. Over SSH (or anywhere without a browser) use `forge-ci login
--manual` and paste the code it asks for. `forge-ci logout` revokes the
token.

For scripts and CI, keep the shared admin token instead — Settings shows the
`export FORGE_CI_URL=… FORGE_CI_ADMIN_TOKEN=…` line:

```sh
curl -H "Authorization: Bearer $FORGE_CI_ADMIN_TOKEN" -H 'Content-Type: application/json' \
     -d '{"name":"myapp","repo_url":"https://github.com/me/myapp.git"}' $FORGE_CI_URL/api/v1/projects

forge-ci trigger .circleci/config.yml --project myapp --wait   # picks the env var up
```

For a private repository without the App, set `CHECKOUT_REPO_URL` on the
runner with a token embedded
(`https://x-access-token:TOKEN@github.com/org/repo.git`) and leave the
project's `repo_url` empty. The full API is in [docs/api.md](docs/api.md).

### Scale runners to zero (AWS)

> Runners have only been tested on AWS EC2 Spot instances (Ubuntu 24.04,
> Auto Scaling Groups in `ap-southeast-3`). Other clouds and bare metal should
> work with the install command but are untested; see
> [TODO.md](TODO.md#tested-so-far).

Runners can cost nothing while nobody is pushing. Give each resource class an
EC2 Auto Scaling Group with a minimum of 0. ForgeCI raises a group's desired
capacity when that class's jobs queue. A runner that has been idle removes
its own instance, so a scale-in never cuts a job short.

1. **Store the runner token** (from Settings) in SSM:
   `aws ssm put-parameter --name /forge-ci/runner-token --type SecureString --value <token>`.
2. **Create a launch template** for each group. Use Ubuntu, an instance
   profile and [`runner/aws/user-data.sh`](runner/aws/user-data.sh) as user
   data, with its settings at the top edited. Set `REQUEUE_ON_SHUTDOWN=1`
   for the Spot group only (it adds `--requeue-on-shutdown`), never for the
   deploy group.

   The instance profile needs:
   - `ssm:GetParameter` on the parameter, plus `kms:Decrypt` for its key;
   - `autoscaling:TerminateInstanceInAutoScalingGroup`;
   - anything your jobs need, such as deploy permissions.
3. **Create the groups** with minimum 0 and desired 0. Checks can use Spot
   through a mixed-instances policy.
4. **Tell ForgeCI about the groups:**

   ```
   FORGE_CI_AUTOSCALE=spot=ci-spot-runners:4,deploy=ci-deploy-runner:1
   FORGE_CI_AUTOSCALE_REGION=ap-southeast-3
   ```

   Each entry is `class=asg-name[:max[:jobs_per_instance]]`. ForgeCI's AWS
   credentials need `autoscaling:DescribeAutoScalingGroups` and
   `autoscaling:SetDesiredCapacity` on those groups.

To have a class's runner boot while the earlier jobs run, for example the
deploy runner during the checks, set `FORGE_CI_AUTOSCALE_WARM=deploy`.

The first job after an idle period waits 1–3 minutes for an instance to boot.
If you use another cloud or your own autoscaler, `GET /api/v1/queue` (admin
token) returns the queued and running jobs per class.

### Operations

- **Update:** `git pull && docker compose up -d --build`. Runners are
  stateless; re-run the install command to update one.
- **Back up** the `pgdata` and `forge-ci-data` volumes together. The
  encryption keys are in `forge-ci-data`, and without them stored contexts and
  the GitHub App key can't be read.
- **Logs:** `docker compose logs -f web`, `journalctl -u forge-ci-runner -f`.
- **Retention:** artifacts are purged after `ARTIFACT_RETENTION_DAYS` (30).
- **Timeouts:** a step is killed after 10 minutes without output and a job
  after an hour. A runner that stops heartbeating has its job reclaimed after
  120 seconds.
- **Rotating tokens:** set `FORGE_CI_ADMIN_TOKEN` or `FORGE_CI_RUNNER_TOKEN`
  to a new value, or delete it from `secrets.yml` and restart. A runner token
  change means re-running the install command on each runner.
- Never expose Postgres publicly. Pull requests from forks never receive
  contexts.

Problems? See [docs/troubleshooting.md](docs/troubleshooting.md).
