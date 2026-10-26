package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// fakeRunnerCP is a scripted control plane for runner-loop tests.
type fakeRunnerCP struct {
	t *testing.T

	mu          sync.Mutex
	claims      []*payload.Claim // popped in order; nil entries mean ErrIdle
	claimErrs   []error          // parallel to claims (takes precedence)
	started     []int64
	heartbeats  []int64
	completions []completion
	releases    []release

	// heartbeatReply is returned for every heartbeat ("" = running).
	heartbeatStatus string
	// claimHook, when set, runs inside Claim just before a claim is
	// returned — a deterministic way to inject a shutdown between the
	// claim response and the runner's Start call.
	claimHook func()
	// idleUpcoming is the upcoming count returned with ErrIdle (default 0).
	idleUpcoming int
	// heartbeatLatency makes heartbeats slow to test finalization races.
	heartbeatLatency  time.Duration
	heartbeatHook     func()
	heartbeatOnce     sync.Once
	heartbeatDone     chan struct{}
	heartbeatDoneOnce sync.Once

	// releaseErr, when set, is returned by Release.
	releaseErr error

	// claimStarted/closed coordinate delayed claims (signal-during-claim).
	claimGate chan struct{}

	claimWaiters int
	claimIdx     int // cursor: how many entries have been popped
}

type completion struct {
	jobID  int64
	status string
}

type release struct {
	jobID  int64
	reason string
}

func (f *fakeRunnerCP) Claim(ctx context.Context, resourceClass string) (*payload.Claim, int, error) {
	f.mu.Lock()
	i := f.claimIdx
	if i < len(f.claimErrs) && f.claimErrs[i] != nil {
		f.claimIdx++
		err := f.claimErrs[i]
		f.mu.Unlock()
		return nil, 0, err
	}
	if i >= len(f.claims) {
		f.claimWaiters++
		f.mu.Unlock()
		// Script exhausted: a responsive control plane with nothing to give.
		time.Sleep(10 * time.Millisecond)
		return nil, f.idleUpcoming, api.ErrIdle
	}
	f.claimIdx++
	claim := f.claims[i]
	hook := f.claimHook
	f.mu.Unlock()
	if claim == nil {
		return nil, f.idleUpcoming, api.ErrIdle
	}
	if hook != nil {
		hook()
	}
	return claim, 0, nil
}

func (f *fakeRunnerCP) Start(ctx context.Context, jobID int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.started = append(f.started, jobID)
	return nil
}

func (f *fakeRunnerCP) Heartbeat(ctx context.Context, jobID int64) (*api.HeartbeatReply, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	f.heartbeatOnce.Do(func() {
		if f.heartbeatHook != nil {
			f.heartbeatHook()
		}
	})
	if f.heartbeatDone != nil {
		defer f.heartbeatDoneOnce.Do(func() { close(f.heartbeatDone) })
	}
	if f.heartbeatLatency > 0 {
		timer := time.NewTimer(f.heartbeatLatency)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.heartbeats = append(f.heartbeats, jobID)
	return &api.HeartbeatReply{ID: jobID, Status: f.heartbeatStatus}, nil
}

func (f *fakeRunnerCP) Complete(ctx context.Context, jobID int64, status string, stepResults []api.StepResult) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.completions = append(f.completions, completion{jobID, status})
	return nil
}

func (f *fakeRunnerCP) Release(ctx context.Context, jobID int64, reason string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.releases = append(f.releases, release{jobID, reason})
	return f.releaseErr
}

func (f *fakeRunnerCP) PutCache(ctx context.Context, projectID int64, key, tarballPath string) (*api.CacheHit, error) {
	return nil, errors.New("unexpected PutCache")
}
func (f *fakeRunnerCP) GetCache(ctx context.Context, projectID int64, keys []string) (*api.CacheHit, error) {
	return nil, nil
}
func (f *fakeRunnerCP) PostArtifact(ctx context.Context, jobID int64, localPath, path, destination string) (*api.ArtifactInfo, error) {
	return nil, errors.New("unexpected PostArtifact")
}
func (f *fakeRunnerCP) Download(ctx context.Context, rawURL, destPath string) error {
	return errors.New("unexpected Download")
}
func (f *fakeRunnerCP) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	return nil
}

func (f *fakeRunnerCP) hasStarted(jobID int64) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, id := range f.started {
		if id == jobID {
			return true
		}
	}
	return false
}

func (f *fakeRunnerCP) completionsFor(jobID int64) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, c := range f.completions {
		if c.jobID == jobID {
			out = append(out, c.status)
		}
	}
	return out
}

func claimJSON(id int64, command string) string {
	return fmt.Sprintf(`{
      "id": %d, "name": "job-%d",
      "executor": {"image": "fake-image"},
      "steps": [{"type": "run", "name": "work", "command": %q}],
      "pipeline": {"sha": "abc", "branch": "main"}
    }`, id, id, command)
}

func mustClaim(t *testing.T, id int64, command string) *payload.Claim {
	t.Helper()
	c, err := payload.ParseClaim([]byte(claimJSON(id, command)))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func runnerCfg(t *testing.T) *config.Config {
	return &config.Config{
		ControlPlaneURL:   "http://cp.invalid",
		RunnerToken:       "tok-12345678",
		DockerBin:         fakeDockerBin(t),
		PollInterval:      0.05,
		MaxIdleInterval:   0.1,
		HeartbeatInterval: 0.05,
		JobTimeout:        30,
		RedactMinLength:   8,
		LogChunkSize:      4096,
		LogFlushInterval:  0,
	}
}

// runOnce starts the loop, waits until every listed job has exactly one
// completion recorded, then shuts the runner down cleanly.
func runOnce(t *testing.T, r *Runner, f *fakeRunnerCP, jobIDs ...int64) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()

	deadline := time.After(30 * time.Second)
	for {
		ready := true
		for _, id := range jobIDs {
			if len(f.completionsFor(id)) != 1 {
				ready = false
				break
			}
		}
		if ready {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("runner exited before finishing jobs: %v", err)
		case <-deadline:
			t.Fatalf("jobs not completed in time: %v", jobIDs)
		case <-time.After(50 * time.Millisecond):
		}
	}
	r.beginShutdown(nil)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runner did not stop in time")
	}
}

func TestJobLifecycleSuccess(t *testing.T) {
	command, _, unblock := gatedCommand(t)
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{mustClaim(t, 101, command)}}
	f.heartbeatHook = unblock
	r := New(runnerCfg(t), f)
	runOnce(t, r, f, 101)

	if !f.hasStarted(101) {
		t.Fatal("job not started")
	}
	if got := f.completionsFor(101); len(got) != 1 || got[0] != "success" {
		t.Fatalf("completions: %v", got)
	}
	f.mu.Lock()
	hb := len(f.heartbeats)
	f.mu.Unlock()
	if hb == 0 {
		t.Fatal("no heartbeats sent")
	}
}

// Race 1+2: signal after claim, before start → canceled, never started.
func TestShutdownAfterClaimBeforeStart(t *testing.T) {
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{mustClaim(t, 102, "true")}}
	cfg := runnerCfg(t)
	r := New(cfg, f)

	// Deliver through the production signal channel while Claim is in flight.
	f.claimHook = func() {
		r.sigCh <- syscall.SIGTERM
		select {
		case <-r.shutdownDone:
		case <-time.After(2 * time.Second):
			t.Error("shutdown signal was not consumed during claim")
		}
	}

	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("runner did not stop")
	}

	if f.hasStarted(102) {
		t.Fatal("job must not be started after shutdown")
	}
	// The claimed job must still be reported (canceled), not abandoned.
	if got := f.completionsFor(102); len(got) != 1 || got[0] != "canceled" {
		t.Fatalf("completions: %v", got)
	}
}

// Race 4: release succeeds server-side but the response is lost — the job
// must not continue locally and the fallback reports canceled.
func TestReleaseFailureFallsBackToCanceled(t *testing.T) {
	command, entered, _ := gatedCommand(t)
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{mustClaim(t, 103, command)}, releaseErr: errors.New("connection reset")}
	cfg := runnerCfg(t)
	cfg.RequeueOnShutdown = true
	r := New(cfg, f)

	// The executor needs a docker bin; give it the fake from the executor
	// tests via a passthrough script that no-ops.
	fake := fakeDockerBin(t)
	cfg.DockerBin = fake

	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	waitForFile(t, entered)
	r.sigCh <- syscall.SIGTERM // exercise production signal consumption

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("runner did not stop")
	}

	if len(f.releases) != 1 {
		t.Fatalf("releases: %+v", f.releases)
	}
	// Release "failed" (response lost) → canceled fallback, exactly once.
	if got := f.completionsFor(103); len(got) != 1 || got[0] != "canceled" {
		t.Fatalf("completions after failed release: %v", got)
	}
}

// Race 3: server cancel races successful completion — complete fires once.
func TestServerCancelRacingCompletion(t *testing.T) {
	command, entered, _ := gatedCommand(t)
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{mustClaim(t, 104, command)}, heartbeatStatus: "canceled"}
	f.heartbeatHook = func() { waitForFile(t, entered) }
	cfg := runnerCfg(t)
	cfg.DockerBin = fakeDockerBin(t)
	r := New(cfg, f)

	runOnce(t, r, f, 104)
	got := f.completionsFor(104)
	if len(got) != 1 {
		t.Fatalf("complete must fire exactly once, got %v", got)
	}
	if got[0] != "canceled" {
		t.Fatalf("canceled job reported as %q", got[0])
	}
}

// Race 5: heartbeat in flight during finalization must not delay it.
func TestHeartbeatInFlightDuringFinalization(t *testing.T) {
	command, _, unblock := gatedCommand(t)
	f := &fakeRunnerCP{
		t:                t,
		claims:           []*payload.Claim{mustClaim(t, 105, command)},
		heartbeatLatency: 3 * time.Second,
		heartbeatDone:    make(chan struct{}),
	}
	f.heartbeatHook = unblock
	cfg := runnerCfg(t)
	cfg.DockerBin = fakeDockerBin(t)
	r := New(cfg, f)

	start := time.Now()
	runOnce(t, r, f, 105)
	select {
	case <-f.heartbeatDone:
	case <-time.After(5 * time.Second):
		t.Fatal("heartbeat did not stop after finalization")
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("finalization waited on the slow heartbeat: %v", elapsed)
	}
	if got := f.completionsFor(105); len(got) != 1 || got[0] != "success" {
		t.Fatalf("completions: %v", got)
	}
}

// Ordinary TERM: the in-flight step finishes, remaining steps are skipped,
// the job is reported canceled (the executor's shutdownCheck path).
func TestOrdinaryShutdownFinishesStep(t *testing.T) {
	command, entered, unblock := gatedCommand(t)
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{
		mustClaim(t, 106, command),
	}}
	f.claims = append(f.claims, mustClaim(t, 107, "true"))
	cfg := runnerCfg(t)
	cfg.DockerBin = fakeDockerBin(t)
	r := New(cfg, f)

	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()

	waitForFile(t, entered)
	r.sigCh <- syscall.SIGTERM
	select {
	case <-r.shutdownDone:
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown signal not consumed")
	}
	unblock()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("run: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("runner did not stop")
	}

	got := f.completionsFor(106)
	if len(got) != 1 || got[0] != "canceled" {
		t.Fatalf("completions: %v", got)
	}
	// No new claims after shutdown: job 107 never started or completed.
	if f.hasStarted(107) || len(f.completionsFor(107)) > 0 {
		t.Fatal("claimed another job after shutdown")
	}
}

// 401 aborts immediately instead of backing off.
func TestUnauthorizedExits(t *testing.T) {
	f := &fakeRunnerCP{t: t, claimErrs: []error{fmt.Errorf("%w (HTTP 401)", api.ErrUnauthorized)}}
	r := New(runnerCfg(t), f)
	start := time.Now()
	err := r.Run(context.Background())
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("401 did not abort quickly: %v", elapsed)
	}
	if !errors.Is(err, api.ErrUnauthorized) {
		t.Fatalf("err: %v", err)
	}
}

// Idle shutdown: after enough idle time the runner exits (running the
// command is out of scope here — empty command).
func TestIdleShutdown(t *testing.T) {
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{nil}, idleUpcoming: 0} // always idle
	cfg := runnerCfg(t)
	cfg.IdleShutdownAfter = 0.2
	r := New(cfg, f)
	start := time.Now()
	if err := r.Run(context.Background()); err != nil {
		t.Fatalf("run: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatal("idle shutdown took too long")
	}
}

// Upcoming>0 must suppress the idle shutdown (work is coming).
func TestUpcomingSuppressesIdleShutdown(t *testing.T) {
	f := &fakeRunnerCP{t: t, claims: []*payload.Claim{nil}, idleUpcoming: 2}
	cfg := runnerCfg(t)
	cfg.IdleShutdownAfter = 0.3
	r := New(cfg, f)

	done := make(chan error, 1)
	go func() { done <- r.Run(context.Background()) }()
	// The fake returns upcoming=2 on idle; the runner must stay up past the
	// idle window.
	select {
	case err := <-done:
		t.Fatalf("runner exited despite upcoming work: %v", err)
	case <-time.After(1 * time.Second):
		r.beginShutdown(nil)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("did not stop")
	}
}

// fakeDockerBin provides the no-op docker script (shared shape with the
// executor tests) without importing their internals.
func fakeDockerBin(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/bash\ncase \"$1\" in\n  info|pull|network|cp|rm|login|buildx) exit 0 ;;\n  run) echo fake-id; exit 0 ;;\n  exec) shift; if [ \"$1\" = \"-d\" ]; then exit 0; fi; while [ \"$1\" = \"-w\" ] || [ \"$1\" = \"-u\" ]; do shift 2; done; while [ \"$1\" = \"-e\" ]; do shift 2; done; shift; exec \"$@\" ;;\n  *) exit 0 ;;\nesac\n"
	path := filepath.Join(dir, "docker")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// gatedCommand holds a real shell step until the test releases it.
func gatedCommand(t *testing.T) (string, string, func()) {
	t.Helper()
	dir := t.TempDir()
	entered, gate := filepath.Join(dir, "entered"), filepath.Join(dir, "gate")
	command := fmt.Sprintf("touch %q; while [ ! -f %q ]; do sleep 0.01; done", entered, gate)
	var once sync.Once
	return command, entered, func() {
		once.Do(func() {
			if err := os.WriteFile(gate, nil, 0o600); err != nil {
				t.Error(err)
			}
		})
	}
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		select {
		case <-tick.C:
		case <-deadline.C:
			t.Errorf("step did not reach %s", path)
			return
		}
	}
}
