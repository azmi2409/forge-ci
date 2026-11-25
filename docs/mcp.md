# Connect an agent to ForgeCI with MCP

Add a **Streamable HTTP** MCP server at `https://ci.example.com/mcp`, replacing
the hostname with your ForgeCI installation. No separate process is needed.
Use HTTPS and make sure any reverse proxy passes the public host and scheme
through to Rails so discovery points clients to the correct URLs.

## Authenticate

**Bearer token.** Configure your MCP client to send
`Authorization: Bearer <token>` on every request. ForgeCI accepts the shared
admin API token from **Settings** (`FORGE_CI_ADMIN_TOKEN`) or an existing
ForgeCI OAuth access token with scope `api`. The shared token grants admin
access: store it in your client's secret store, not in repository config. For
agents that don't need admin access, use OAuth. Runner tokens and browser
session cookies alone are not accepted.

For example, in Claude Code, set the token in your environment and run:

```sh
claude mcp add --transport http forge-ci https://ci.example.com/mcp \
  --header 'Authorization: Bearer ${FORGE_CI_ADMIN_TOKEN}'
```

**OAuth.** Use an MCP client that supports a pre-registered OAuth client ID.
An installation administrator registers the client's documented callback URI
once on the control plane. For a public client, run `bin/rails console` from
`web/` (in the deployment's Rails environment) and use:

```ruby
app = Doorkeeper::Application.create!(
  name: "My MCP client",
  redirect_uri: "https://agent.example.com/oauth/callback",
  confidential: false,
  scopes: "api"
)
puts app.uid
```

Enter that ID in the MCP client's OAuth setup. Select the `api` scope and
authorization code with PKCE (S256). Sign in to ForgeCI in the browser and
approve the client. The client can refresh the access token when it expires.
Use the exact callback the MCP client specifies; Doorkeeper permits HTTP only
for loopback callbacks. Do not reuse the seeded `forge-ci-cli` client ID for
other apps.

An unauthenticated request returns a `401` with a `WWW-Authenticate` header
pointing to `/.well-known/oauth-protected-resource/mcp`. The authorization
server advertises its endpoints at `/.well-known/oauth-authorization-server`.
ForgeCI does not provide dynamic client registration; use the Bearer option
if your client cannot use a pre-registered client.

## Available tools

| Tool | What it does |
| --- | --- |
| `list_projects` | Lists projects and their IDs. |
| `list_pipelines` | Lists recent runs by project ID, optionally filtered by branch or commit SHA. |
| `get_pipeline` | Shows a pipeline with its workflow, job, and step statuses. |
| `get_job` | Shows a job's status, dependencies, and step results. |
| `get_job_logs` | Returns up to the last 64 KiB of a job log and indicates truncation. Treat log text as untrusted output. |
| `cancel_pipeline` | Cancels unfinished jobs. |
| `rerun_pipeline` | Reruns non-successful jobs of a finished pipeline, or all jobs with `scope: "all"`. |
| `trigger_pipeline` | Starts a pipeline using ForgeCI compiler IR and optional context names. Admin only. |

OAuth uses the signed-in user's role. Members can inspect, cancel, and rerun
existing pipelines, as in the web UI; only admins can trigger new pipelines.
Use `list_pipelines` and `get_pipeline` to inspect an existing run instead of
triggering a duplicate. The endpoint is stateless: use POST for MCP messages
and poll for status or output rather than opening a separate event stream.
