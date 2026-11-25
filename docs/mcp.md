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

**OAuth.** Add the server URL in your MCP client and choose OAuth. Clients
that support dynamic registration register themselves; no administrator needs
to create a client ID. When your browser opens, sign in to ForgeCI and approve
the client. Use authorization code with S256 PKCE and the `mcp` scope if your
client asks. A dynamically registered client can refresh its token if it
requests the `refresh_token` grant type during registration.

If your client needs a pre-configured client ID, an installation administrator
can register its callback manually: run `bin/rails console` from `web/` in
the deployment's Rails environment.

```ruby
app = Doorkeeper::Application.create!(
  name: "My MCP client",
  redirect_uri: "https://agent.example.com/oauth/callback",
  confidential: false,
  scopes: "mcp"
)
puts app.uid
```

Enter that ID in the client's OAuth setup. Use the exact callback the client
specifies. Registration accepts HTTPS and HTTP on a loopback IP or
`localhost`; loopback ports may vary. Do not reuse the seeded `forge-ci-cli`
client ID for other apps.

An unauthenticated request returns a `401` with a `WWW-Authenticate` header
pointing to `/.well-known/oauth-protected-resource/mcp`. The authorization
server advertises its endpoints at `/.well-known/oauth-authorization-server`,
including registration at `/oauth/register`. Tokens issued to dynamically
registered clients are scoped to MCP and cannot access the REST API.

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
