package executor

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// fakeDocker installs a fake docker CLI that records invocations and runs
// `exec` commands locally (no containers involved).
func fakeDocker(t *testing.T) (bin string, logPath string) {
	t.Helper()
	dir := t.TempDir()
	logPath = filepath.Join(dir, "calls.log")
	script := fmt.Sprintf(`#!/bin/bash
LOG=%q
echo "$*" >> "$LOG"
case "$1" in
  cp)
    src="$2"; dst="$3"
    case "$src" in *:*) src="${src#*:}";; esac
    case "$dst" in *:*) dst="${dst#*:}";; esac
    cp "$src" "$dst"; exit 0 ;;
  info|pull|network|rm|login|buildx|mkdir|chmod) exit 0 ;;
  run) echo "fake-container-id"; exit 0 ;;
  exec)
    shift
    if [ "$1" = "-d" ]; then exit 0; fi
    while [ "$1" = "-w" ] || [ "$1" = "-u" ]; do shift 2; done
    while [ "$1" = "-e" ]; do export "${2%%=*}=${2#*=}"; shift 2; done
    shift
    exec "$@"
    ;;
  *) exit 0 ;;
esac
`, logPath)
	bin = filepath.Join(dir, "docker")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, logPath
}

// fakeCP records everything the executor sends.
type fakeCP struct {
	mu        sync.Mutex
	chunks    []string
	seqs      []int64
	artifacts []string
	caches    []string
	downloads []string
}

func (f *fakeCP) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.chunks = append(f.chunks, chunk)
	f.seqs = append(f.seqs, seq)
	return nil
}

func (f *fakeCP) PutCache(ctx context.Context, projectID int64, key, tarballPath string) (*api.CacheHit, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.caches = append(f.caches, key)
	return &api.CacheHit{Key: key, Size: 10}, nil
}

func (f *fakeCP) GetCache(ctx context.Context, projectID int64, keys []string) (*api.CacheHit, error) {
	return nil, nil
}

func (f *fakeCP) PostArtifact(ctx context.Context, jobID int64, localPath, path, destination string) (*api.ArtifactInfo, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.artifacts = append(f.artifacts, path)
	return &api.ArtifactInfo{ID: 1, Path: path}, nil
}

func (f *fakeCP) Download(ctx context.Context, rawURL, destPath string) error {
	f.downloads = append(f.downloads, rawURL)
	return nil
}

func (f *fakeCP) log() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.chunks, "")
}

func (f *fakeCP) stepSeqs() []int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.seqs
}

func readDockerLog(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read docker log: %v", err)
	}
	return string(b)
}

// waitDockerLog polls until the fake docker log contains substr (with
// timeout) — used to synchronize on setup progress before signaling. The
// log file may not exist yet in early polls; that is not fatal.
func waitDockerLog(t *testing.T, path, substr string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil && strings.Contains(string(b), substr) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	b, _ := os.ReadFile(path)
	t.Fatalf("docker log never contained %q: %s", substr, b)
}

func testCfg(dockerBin string) *config.Config {
	return &config.Config{
		ControlPlaneURL:     "http://cp.invalid",
		RunnerToken:         "tok-12345678",
		DockerBin:           dockerBin,
		DockerSocketPath:    "/var/run/docker.sock",
		RedactMinLength:     8,
		JobTimeout:          60,
		StepNoOutputTimeout: 30,
		LogChunkSize:        4096,
		LogFlushInterval:    0,
	}
}

// runLifecycle executes a job against a fake docker. Mode:
//   - "": no interrupt
//   - "cancel": caller context canceled ~200ms after setup completed (mid-step)
//   - "requeue": the shutdown check fires ~200ms after setup (mid-step);
//     requires cfg.RequeueOnShutdown
func runLifecycle(t *testing.T, claimJSON string, cfg *config.Config, mode string) (string, []api.StepResult, *fakeCP, string, *Executor) {
	t.Helper()
	bin, dockerLogPath := fakeDocker(t)
	if cfg == nil {
		cfg = testCfg(bin)
	} else {
		cfg.DockerBin = bin
	}
	claim, err := payload.ParseClaim([]byte(claimJSON))
	if err != nil {
		t.Fatal(err)
	}
	cp := &fakeCP{}
	e := New(cfg, cp, claim)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cancelCheck := func() bool { return false }
	shutdownCheck := func() bool { return false }
	switch mode {
	case "cancel":
		go func() {
			waitDockerLog(t, dockerLogPath, "circleci_cli.sh")
			time.Sleep(200 * time.Millisecond)
			cancel()
		}()
		cancelCheck = func() bool { return ctx.Err() != nil }
	case "requeue":
		triggered := make(chan struct{})
		go func() {
			waitDockerLog(t, dockerLogPath, "circleci_cli.sh")
			time.Sleep(200 * time.Millisecond)
			close(triggered)
		}()
		shutdownCheck = func() bool {
			select {
			case <-triggered:
				return true
			default:
				return false
			}
		}
	}

	status, results := e.Execute(ctx, shutdownCheck, cancelCheck)
	return status, results, cp, dockerLogPath, e
}

func TestExecuteSuccess(t *testing.T) {
	claim := `{
      "id": 21, "name": "happy",
      "executor": {"image": "cimg/base:current"},
      "steps": [
        {"type": "run", "name": "first", "command": "echo step-one-output"},
        {"type": "run", "name": "second", "command": "echo step-two-output"}
      ],
      "environment": {"JOBVAR": "plain"},
      "pipeline": {"sha": "abc", "branch": "main"}
    }`
	status, results, cp, dockerLogPath, exec := runLifecycle(t, claim, nil, "")
	dockerLog := readDockerLog(t, dockerLogPath)
	if status != StatusSuccess {
		t.Fatalf("status %s; log=%s", status, cp.log())
	}
	if len(results) != 2 || results[0].ExitCode != 0 || results[1].ExitCode != 0 {
		t.Fatalf("results: %+v", results)
	}
	if results[0].Name != "first" || results[1].Name != "second" {
		t.Fatalf("names: %+v", results)
	}
	log := cp.log()
	if !strings.Contains(log, "step-one-output") || !strings.Contains(log, "step-two-output") {
		t.Fatalf("output missing: %q", log)
	}
	// Setup + cleanup ran through the fake docker.
	for _, frag := range []string{"pull cimg/base:current", "network create", "run -d"} {
		if !strings.Contains(dockerLog, frag) {
			t.Errorf("docker log missing %q: %s", frag, dockerLog)
		}
	}
	if !strings.Contains(dockerLog, "rm -f forge-ci-job-21-") {
		t.Errorf("container cleanup missing: %s", dockerLog)
	}
	if !strings.Contains(dockerLog, "network rm") {
		t.Errorf("network cleanup missing: %s", dockerLog)
	}
	// The script temp dir of THIS executor is removed by cleanup.
	if dir := exec.ScriptDir(); dir != "" {
		if _, err := os.Stat(dir); !os.IsNotExist(err) {
			t.Errorf("script temp dir leaked: %s", dir)
		}
	}
}

func TestExecuteFailureAndWhen(t *testing.T) {
	claim := `{
      "id": 22, "name": "failing",
      "executor": {"image": "cimg/base:current"},
      "steps": [
        {"type": "run", "name": "boom", "command": "echo before-boom; exit 3"},
        {"type": "run", "name": "never", "command": "echo should-not-run"},
        {"type": "run", "name": "rescue", "command": "echo on-fail-ran", "when": "on_fail"},
        {"type": "run", "name": "always", "command": "echo always-ran", "when": "always"},
        {"type": "save_cache", "key": "k", "paths": ["x"], "when": "always"},
        {"type": "store_test_results", "path": "tmp", "when": "always"},
        {"type": "teleport", "command": "???", "when": "always"}
      ],
      "pipeline": {"sha": "abc", "branch": "main"}
    }`
	status, results, cp, _, _ := runLifecycle(t, claim, nil, "")
	if status != StatusFailed {
		t.Fatalf("status %s", status)
	}
	if len(results) != 7 {
		t.Fatalf("results: %+v", results)
	}
	log := cp.log()
	if !strings.Contains(log, "on-fail-ran") {
		t.Error("on_fail step must run after a failure")
	}
	if !strings.Contains(log, "always-ran") {
		t.Error("always step must run after a failure")
	}
	if strings.Contains(log, "should-not-run") {
		t.Error("on_success step must be skipped after a failure")
	}
	if results[2].ExitCode != 0 || !strings.Contains(log, "step skipped: never") {
		t.Errorf("skipped step must be reported with exit 0: %+v", results[1])
	}
	if results[0].ExitCode != 3 {
		t.Errorf("failing step exit: %+v", results[0])
	}
	// Cache step without project_id skips loudly.
	if !strings.Contains(log, "carries no project_id") {
		t.Error("save_cache without project_id must warn")
	}
	// Deferred + unknown steps skip loudly.
	if !strings.Contains(log, "not implemented yet") || !strings.Contains(log, "unknown step type") {
		t.Error("deferred/unknown steps must warn")
	}
}

func TestExecuteRedaction(t *testing.T) {
	claim := `{
      "id": 23, "name": "secrets",
      "executor": {"image": "cimg/base:current"},
      "steps": [
        {"type": "run", "name": "leak", "command": "echo token=$SECRET_VALUE"}
      ],
      "environment": {"SECRET_VALUE": "super-secret-env-value"},
      "pipeline": {}
    }`
	status, _, cp, _, _ := runLifecycle(t, claim, nil, "")
	if status != StatusSuccess {
		t.Fatalf("status %s", status)
	}
	log := cp.log()
	if strings.Contains(log, "super-secret-env-value") {
		t.Fatalf("secret leaked into the log: %q", log)
	}
	if !strings.Contains(log, "[REDACTED]") {
		t.Fatalf("secret not redacted: %q", log)
	}
}

func TestRedactorIncludesExplicitShortAndStepServiceSecrets(t *testing.T) {
	claimJSON := `{
      "id": 26, "name": "redaction-sources",
      "executor": {"image": "cimg/base:current", "secondary_images": [
        {"image": "postgres:16", "environment": {"SERVICE_SECRET": "service-secret-value"}}
      ]},
      "steps": [{"type": "run", "environment": {"STEP_SECRET": "step-secret-value"}}],
      "environment": {"RAILS_ENV": "test"},
      "secret_values": ["s3cr3t"],
      "pipeline": {}
    }`
	claim, err := payload.ParseClaim([]byte(claimJSON))
	if err != nil {
		t.Fatal(err)
	}
	e := New(testCfg(""), &fakeCP{}, claim)
	for _, secret := range []string{"s3cr3t", "step-secret-value", "service-secret-value"} {
		if got := e.redactor.Redact(secret); got != "[REDACTED]" {
			t.Errorf("%q was not redacted: %q", secret, got)
		}
	}
}

func TestExecuteCancelMidStep(t *testing.T) {
	claim := `{
      "id": 24, "name": "canceled",
      "executor": {"image": "cimg/base:current"},
      "steps": [
        {"type": "run", "name": "long", "command": "echo started && sleep 30"},
        {"type": "run", "name": "after", "command": "echo after"}
      ],
      "pipeline": {}
    }`
	start := time.Now()
	status, results, cp, _, _ := runLifecycle(t, claim, nil, "cancel")
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("cancel took %v", elapsed)
	}
	if status != StatusCanceled {
		t.Fatalf("status %s log=%s", status, cp.log())
	}
	log := cp.log()
	if !strings.Contains(log, "step stopped: job was canceled") {
		t.Errorf("cancel note missing: %q", log)
	}
	if !strings.Contains(log, "step skipped: after (") || strings.Contains(log, "--- step: after (") {
		t.Errorf("remaining step must be skipped: %q", log)
	}
	if len(results) != 2 {
		t.Fatalf("results: %+v", results)
	}
}

func TestExecuteRequeueMidStep(t *testing.T) {
	claim := `{
      "id": 25, "name": "requeued",
      "executor": {"image": "cimg/base:current"},
      "steps": [
        {"type": "run", "name": "long", "command": "sleep 30"},
        {"type": "run", "name": "after", "command": "echo after"}
      ],
      "pipeline": {}
    }`
	cfg := testCfg("")
	cfg.RequeueOnShutdown = true
	status, results, cp, _, _ := runLifecycle(t, claim, cfg, "requeue")

	if status != StatusRequeue {
		t.Fatalf("status %s log=%s", status, cp.log())
	}
	if !strings.Contains(cp.log(), "the job goes back to the queue") {
		t.Errorf("requeue note missing: %q", cp.log())
	}
	if len(results) != 2 {
		t.Fatalf("results: %+v", results)
	}
}

func TestExecuteNoOutputTimeout(t *testing.T) {
	claim := `{
      "id": 26, "name": "silent",
      "executor": {"image": "cimg/base:current"},
      "steps": [{"type": "run", "name": "quiet", "command": "sleep 8"}],
      "pipeline": {}
    }`
	cfg := testCfg("")
	cfg.StepNoOutputTimeout = 0.5
	start := time.Now()
	status, _, cp, _, _ := runLifecycle(t, claim, cfg, "")
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("no-output kill took %v", elapsed)
	}
	if status != StatusFailed {
		t.Fatalf("status %s", status)
	}
	if !strings.Contains(cp.log(), "no_output_timeout") {
		t.Errorf("timeout note missing: %q", cp.log())
	}
}

func TestExecuteJobTimeout(t *testing.T) {
	claim := `{
      "id": 27, "name": "slow",
      "executor": {"image": "cimg/base:current"},
      "steps": [{"type": "run", "name": "long", "command": "sleep 30"}],
      "pipeline": {}
    }`
	cfg := testCfg("")
	cfg.JobTimeout = 1
	start := time.Now()
	status, _, cp, _, e := runLifecycle(t, claim, cfg, "")
	if elapsed := time.Since(start); elapsed > 6*time.Second {
		t.Fatalf("job deadline kill took %v", elapsed)
	}
	if status != StatusFailed {
		t.Fatalf("status %s log=%s", status, cp.log())
	}
	if e.runCtx.Err() != context.DeadlineExceeded {
		t.Errorf("job deadline did not expire: %v", e.runCtx.Err())
	}
}

func TestExecuteSetupFailureStillCleans(t *testing.T) {
	claim := `{"id": 28, "name": "noimage", "steps": [], "pipeline": {}}`
	status, results, _, dockerLogPath, _ := runLifecycle(t, claim, nil, "")
	if status != StatusFailed {
		t.Fatalf("status %s", status)
	}
	if len(results) != 0 {
		t.Fatalf("results: %+v", results)
	}
	// Cleanup still ran (rm -f attempts + network rm are logged by the fake).
	dockerLog := readDockerLog(t, dockerLogPath)
	if !strings.Contains(dockerLog, "network rm") {
		t.Errorf("cleanup must run even after setup failure: %s", dockerLog)
	}
}

func TestExecuteSetupCancellation(t *testing.T) {
	for _, beforeExecute := range []bool{true, false} {
		for _, requeue := range []bool{false, true} {
			t.Run(fmt.Sprintf("before=%t/requeue=%t", beforeExecute, requeue), func(t *testing.T) {
				dir := t.TempDir()
				bin := filepath.Join(dir, "docker")
				logPath := filepath.Join(dir, "calls.log")
				script := fmt.Sprintf("#!/bin/sh\necho \"$*\" >> %q\nif [ \"$1\" = pull ]; then exec sleep 30; fi\n", logPath)
				if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
					t.Fatal(err)
				}
				claim, err := payload.ParseClaim([]byte(`{"id": 30, "name": "setup-cancel", "executor": {"image": "busybox"}, "steps": [{"type": "run", "command": "echo must-not-run"}]}`))
				if err != nil {
					t.Fatal(err)
				}
				cfg := testCfg(bin)
				cfg.RequeueOnShutdown = requeue
				e := New(cfg, &fakeCP{}, claim)
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				if beforeExecute {
					cancel()
				}
				done := make(chan string, 1)
				go func() {
					status, _ := e.Execute(ctx,
						func() bool { return requeue && ctx.Err() != nil },
						func() bool { return !requeue && ctx.Err() != nil })
					done <- status
				}()
				if !beforeExecute {
					waitDockerLog(t, logPath, "pull busybox")
					cancel()
				}
				select {
				case status := <-done:
					want := StatusCanceled
					if requeue {
						want = StatusRequeue
					}
					if status != want {
						t.Errorf("status = %s; want %s", status, want)
					}
				case <-time.After(10 * time.Second):
					t.Fatal("setup cancellation did not stop pull")
				}
				log := readDockerLog(t, logPath)
				if strings.Contains(log, "network create") || strings.Contains(log, "exec ") {
					t.Errorf("setup continued after cancellation: %s", log)
				}
				if !strings.Contains(log, "rm -f ") || !strings.Contains(log, "network rm ") {
					t.Errorf("cleanup missing after cancellation: %s", log)
				}
			})
		}
	}
}

func TestSeqOrderInLog(t *testing.T) {
	claim := `{
      "id": 29, "name": "ordered",
      "executor": {"image": "cimg/base:current"},
      "steps": [{"type": "run", "name": "a", "command": "echo one"}, {"type": "run", "name": "b", "command": "echo two"}],
      "pipeline": {}
    }`
	_, _, cp, _, _ := runLifecycle(t, claim, nil, "")
	seqs := cp.stepSeqs()
	for i, seq := range seqs {
		if seq != int64(i) {
			t.Fatalf("seqs not in order: %v", seqs)
		}
	}
}

// Guard: the fake docker actually gets used (not the real one).
func TestFakeDockerIsolation(t *testing.T) {
	bin, logPath := fakeDocker(t)
	out, err := os.ReadFile(logPath)
	if err == nil && len(out) > 0 {
		t.Fatalf("fake docker log should start empty: %s", out)
	}
	if !strings.HasPrefix(bin, "/") {
		t.Fatalf("bin path: %s", bin)
	}
	re := regexp.MustCompile(`^docker$`)
	if re.MatchString(bin) {
		t.Fatal("must not shadow the real docker")
	}
}

func TestInterruptedStepStopsContainerBeforeSkippingFailureSteps(t *testing.T) {
	claim := `{
	  "id": 61, "name": "timeout", "executor": {"image": "fake"},
	  "steps": [
	    {"type": "run", "command": "sleep 8"},
	    {"type": "run", "command": "echo must-not-run", "when": "always"}
	  ]
	}`
	cfg := testCfg("")
	cfg.StepNoOutputTimeout = 0.1
	status, results, cp, dockerLogPath, e := runLifecycle(t, claim, cfg, "")
	if status != StatusFailed || len(results) != 2 || results[0].ExitCode != timeoutExit {
		t.Fatalf("status=%s results=%+v", status, results)
	}
	if !strings.Contains(cp.log(), "step skipped:") || strings.Contains(cp.log(), "must-not-run") {
		t.Fatalf("failure step ran after interruption: %s", cp.log())
	}
	// One immediate removal at interruption, another idempotent cleanup.
	if calls := readDockerLog(t, dockerLogPath); strings.Count(calls, "rm -f "+e.container+"\n") != 2 {
		t.Fatalf("interruption did not remove primary before final cleanup: %s", calls)
	}
}

func TestRedactsEveryEnvironmentScopeAndShadowedValue(t *testing.T) {
	claim := `{
	  "id": 62, "name": "secrets", "environment": {"SECRET": "job-secret-value"},
	  "executor": {"image": "fake", "secondary_images": [
	    {"image": "redis", "environment": {"SECRET": "service-secret-value"}}
	  ]},
	  "steps": [
	    {"type": "run", "environment": {"SECRET": "step-first-value"}, "command": "echo job-secret-value step-first-value service-secret-value"},
	    {"type": "run", "environment": {"SECRET": "step-next-value"}, "command": "echo step-next-value"}
	  ]
	}`
	status, _, cp, _, _ := runLifecycle(t, claim, nil, "")
	if status != StatusSuccess {
		t.Fatalf("status=%s log=%s", status, cp.log())
	}
	for _, secret := range []string{"job-secret-value", "service-secret-value", "step-first-value", "step-next-value"} {
		if strings.Contains(cp.log(), secret) {
			t.Errorf("secret leaked: %s", secret)
		}
	}
}

func TestServiceFailedStartRemovesOnlyOwnedContainer(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "calls.log")
	bin := filepath.Join(dir, "docker")
	script := fmt.Sprintf("#!/bin/sh\necho \"$*\" >> %q\ncase \"$1\" in run) exit 1;; esac\n", logPath)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	claim, err := payload.ParseClaim([]byte(`{"id":63,"name":"service","executor":{"image":"fake","secondary_images":[{"image":"redis","name":"unrelated-host-container"}]}}`))
	if err != nil {
		t.Fatal(err)
	}
	e := New(testCfg(bin), &fakeCP{}, claim)
	status, _ := e.Execute(context.Background(), func() bool { return false }, func() bool { return false })
	calls := readDockerLog(t, logPath)
	if status != StatusFailed || !strings.Contains(calls, "rm -f forge-ci-svc-0-"+e.suffix) {
		t.Fatalf("failed service start leaked container: status=%s calls=%s", status, calls)
	}
	if strings.Contains(calls, "--name unrelated-host-container") || strings.Contains(calls, "rm -f unrelated-host-container") {
		t.Fatalf("payload controlled host container name: %s", calls)
	}
}

func TestOrdinaryShutdownDuringFinalStepReportsCanceled(t *testing.T) {
	bin, logPath := fakeDocker(t)
	claim, err := payload.ParseClaim([]byte(`{"id":64,"name":"final","executor":{"image":"fake"},"steps":[{"type":"run","command":"echo final-step-started; sleep 0.2; echo final-step-finished"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	cp := &fakeCP{}
	e := New(testCfg(bin), cp, claim)
	shutdown := func() bool {
		calls, _ := os.ReadFile(logPath)
		return strings.Contains(string(calls), "echo final-step-started")
	}
	status, results := e.Execute(context.Background(), shutdown, func() bool { return false })
	if status != StatusCanceled || len(results) != 1 || results[0].ExitCode != 0 || !strings.Contains(cp.log(), "final-step-finished") {
		t.Fatalf("status=%s results=%+v log=%s", status, results, cp.log())
	}
}
