# Go runner test coverage matrix

The rewrite is inventory-driven (test counts are not the criterion): every
behavior in the Ruby suite (`runner/test/`) maps to a Go test, and the Go
suite adds coverage the Ruby one lacked (boundary-safe streaming, lifecycle
races, real-container integration). Run everything with:

```sh
cd runner-go && go test -race ./...
```

CI note: the Docker integration test skips locally without a daemon but is a
REQUIRED job in CI (see plan Phase 8).

## Ruby suite → Go suite

| Ruby test (runner/test/) | Go coverage | Notes |
|---|---|---|
| `backoff_test.rb` | `internal/backoff` | tick/reset/cap, custom factor |
| `cache_artifact_test.rb` | `internal/api` (multipart, hit/miss/404/403) + `internal/executor` cache_flow tests | streaming multipart with exact Content-Length |
| `cache_steps_test.rb` | `internal/executor/cache_flow_test.go` | save/restore round trip via checksum keys, clean miss, workspace persist/attach with manifest, artifacts upload content |
| `circleci_cli_test.rb` | `internal/executor/scripts_test.go` | embedded helper must stay byte-identical to `runner/lib` canonical; glob/split(name)/run behavior via real bash ≥4 |
| `client_test.rb` | `internal/api/api_test.go` | golden fixtures from `contract/`, 422+upcoming, 401, redirect rules, no-auth signed downloads, atomic `.part` publish |
| `config_test.rb` | `internal/config` | required vars, token file, Ruby to_f/to_i semantics, boolean parsing |
| `docker_layer_cache_test.rb` | `internal/executor/args_test.go` | build-cache env (refs, IMAGE w/o host, creds absent when unauthenticated), login argv (password via env, never argv), buildx argv set |
| `executor_test.rb` | `internal/executor/args_test.go` + `executor_test.go` + `proc_test.go` | pure argv builders (CircleCI env, precedence, socket args, workspace keys, shellwords/quote, userinfo stripping) |
| `key_template_test.rb` | `internal/keytemplate` | checksum/branch/epoch, unknown preserved + warned |
| `log_streamer_test.rb` | `internal/logstream` | chunk splitting, ordered seqs, retry reuses seq (3 attempts, 2×1s), drop-after-retries, close drains; PLUS split-secret retention across writes and timer flushes, UTF-8 boundary preservation, invalid-byte → U+FFFD, bounded backpressure, concurrent writers |
| `multipart_test.rb` | `internal/api` | replaced by mime multipart with computed length (never chunked) |
| `redactor_test.rb` | `internal/redact` | longest-first literal, min length, dedupe, MaxSecretLen |
| `requeue_on_shutdown_test.rb` | `internal/runner/runner_test.go` + `internal/executor/executor_test.go` | requeue mid-step: interrupt → containers stopped → logs drained → release; release failure → canceled fallback; released job never continues locally |
| `runner_loop_test.rb` | `internal/runner/runner_test.go` | claim→start→heartbeat→complete; idle backoff, upcoming suppression, idle shutdown, 401 exit; PLUS the five required races: signal during claim, signal after claim before start (hook-injected), cancel vs completion (complete once), release response lost, heartbeat in flight at finalization (bounded 2s) |
| `step_planner_test.rb` | `internal/planner` | ordering, display names, `when` semantics |
| `tarball_test.rb` | `internal/tarutil` | create/extract, missing-path warnings, nothing-to-archive |
| `timeout_cancel_test.rb` | `internal/executor/executor_test.go` + `proc_test.go` | no-output 124, job deadline 124, cancel 130, process-group TERM→KILL, ctx cancellation of arbitrary docker ops |

## Go-only coverage (beyond the Ruby suite)

- **Contract fixtures** (`contract/*.json`): golden claim/lifecycle/cache/
  artifact payloads decoded by `internal/payload` — pins absence-vs-null
  (`trusted`, executor fields, `destination: null`), unknown-step raw
  retention, environment stringification. Validated against a live
  Rails/PostgreSQL control plane in the Phase 8 soak.
- **Fake-docker lifecycle** (`executor_test.go`): full job execution with
  process groups, when-semantics, redaction end-to-end, bounded cleanup
  after setup failure, script temp-dir removal.
- **Real-container integration** (`integration_docker_test.go`, Docker-
  gated, CI-required): busybox job, in-container redaction, when semantics,
  and post-run leak checks (no containers/networks/builders left).
- **Process groups** (`proc_test.go`): grandchild kill via group signal,
  bounded-quantity output chunks, missing-binary errors.
- **Streaming rigor** (`logstream_test.go`): newline-free output flow,
  activity = bytes received, queue-bound backpressure.

## Known behavioral parity notes

- Ordinary TERM lets the in-flight step finish (Ruby parity); requeue TERM
  interrupts it.
- Timer flushes never expose the secret-retention tail (stricter than Ruby,
  which redacted per read and could leak split secrets).
- Log chunks post strictly in seq order through one sender (Ruby used a
  post mutex; same observable order).
- `docker exec` client kill is followed by explicit container removal on
  job-level interruption (Ruby relied on the ensure-block cleanup only).
