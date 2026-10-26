// Package runner is the daemon loop: poll → claim → start → execute →
// complete, with four deliberately separate lifetimes (never one context
// derived from the signal):
//
//	stopClaiming        closed by SIGTERM/SIGINT — no new claims
//	interruptExecution  server cancel or requeue shutdown — stops the
//	                    in-flight step and docker operations
//	heartbeats          per-job goroutine, bounded at finalization
//	finalize/report     bounded client calls, usable after shutdown
//
// Shutdown semantics (matching the Ruby runner exactly):
//   - ordinary TERM: stop claiming; the in-flight step FINISHES; remaining
//     steps are skipped; the job is reported canceled; exit cleanly.
//   - requeue TERM (REQUEUE_ON_SHUTDOWN): interrupt execution, stop
//     containers, drain logs, then RELEASE the job back to the queue; if
//     the release is refused (409, older server) or unreachable, report it
//     canceled instead. A released job never continues executing locally.
//
// No blind retries: complete/release/start fire once (the server does not
// guarantee idempotency); only the log-chunk endpoint is idempotent and the
// logstream owns its retries.
package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/backoff"
	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/executor"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
	"github.com/azmi2409/forge-ci/runner-go/internal/version"
)

// ControlPlane is everything the runner needs from the client (the executor
// subset is embedded so one fake can serve both).
type ControlPlane interface {
	executor.ControlPlane
	Claim(ctx context.Context, resourceClass string) (*payload.Claim, int, error)
	Outlook(ctx context.Context, resourceClass string) (*api.Outlook, error)
	Start(ctx context.Context, jobID int64) error
	Heartbeat(ctx context.Context, jobID int64) (*api.HeartbeatReply, error)
	Complete(ctx context.Context, jobID int64, status string, stepResults []api.StepResult) error
	Release(ctx context.Context, jobID int64, reason string) error
}

// Runner is the daemon.
type Runner struct {
	cfg     *config.Config
	client  ControlPlane
	backoff *backoff.Backoff

	shuttingDown   atomic.Bool // stopClaiming lifetime
	shutdownSignal string
	shutdownMu     sync.Mutex
	shutdownDone   chan struct{}

	// execCancel interrupts the current job's execution (interruptExecution
	// lifetime): set by server-cancel or requeue shutdown.
	execCancel atomic.Value // context.CancelFunc

	logMu sync.Mutex
	// idleSince tracks the last moment work was seen, for scale-to-zero.
	idleSince time.Time

	sigCh chan os.Signal
}

func New(cfg *config.Config, client ControlPlane) *Runner {
	return &Runner{
		cfg:          cfg,
		client:       client,
		backoff:      backoff.New(cfg.PollInterval, cfg.MaxIdleInterval),
		sigCh:        make(chan os.Signal, 1),
		shutdownDone: make(chan struct{}),
	}
}

// Run polls until shutdown. A 401 (bad token) aborts immediately — backing
// off cannot heal it. Returns nil on clean shutdown.
func (r *Runner) Run(ctx context.Context) error {
	signal.Notify(r.sigCh, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(r.sigCh)
	watchDone := make(chan struct{})
	watchStopped := make(chan struct{})
	go func() {
		defer close(watchStopped)
		select {
		case sig := <-r.sigCh:
			r.beginShutdown(sig)
		case <-ctx.Done():
			r.beginShutdown(nil)
		case <-watchDone:
		}
	}()
	defer func() { close(watchDone); <-watchStopped }()

	r.logf("forge-ci-runner %s starting (%s, resource_class=%s)",
		version.Version, r.cfg.ControlPlaneURL, orDefault(r.cfg.ResourceClass, "any"))
	r.idleSince = time.Now()
	var lingerUntil time.Time

	for {
		if ctx.Err() != nil {
			r.beginShutdown(nil)
		}
		if r.shuttingDown.Load() {
			break
		}

		claimCtx := ctx
		var cancelClaim context.CancelFunc
		if !lingerUntil.IsZero() {
			if !time.Now().Before(lingerUntil) {
				r.idleShutdown()
				return nil
			}
			claimCtx, cancelClaim = context.WithDeadline(ctx, lingerUntil)
		}
		claim, _, err := r.client.Claim(claimCtx, r.cfg.ResourceClass)
		if cancelClaim != nil {
			cancelClaim()
		}
		if err != nil {
			if errors.Is(err, context.Canceled) {
				r.beginShutdown(nil)
				if r.shuttingDown.Load() {
					break
				}
				return ctx.Err()
			}
			if errors.Is(err, api.ErrUnauthorized) {
				r.logf("%v; exiting", err)
				return err
			}
			if !errors.Is(err, api.ErrIdle) {
				r.logf("control plane error: %v; backing off", err)
			}
		}

		if err != nil && r.cfg.IdleShutdownAfter > 0 && r.idleTooLong() {
			if r.cfg.IdleLingerMax <= 0 {
				r.idleShutdown()
				return nil
			}
			if lingerUntil.IsZero() {
				baseDeadline := r.idleSince.Add(seconds(r.cfg.IdleShutdownAfter))
				lingerUntil = baseDeadline.Add(seconds(r.cfg.IdleLingerMax))
			}
			if !time.Now().Before(lingerUntil) {
				r.idleShutdown()
				return nil
			}
			outlookCtx, cancelOutlook := context.WithDeadline(ctx, lingerUntil)
			outlook, outlookErr := r.client.Outlook(outlookCtx, r.cfg.ResourceClass)
			cancelOutlook()
			if outlookErr != nil {
				r.logf("runner outlook unavailable (%v); shutting down at base idle", outlookErr)
				r.idleShutdown()
				return nil
			}
			if !outlook.HasWork() || !time.Now().Before(lingerUntil) {
				r.idleShutdown()
				return nil
			}
			r.pause(lingerPause(r.cfg.IdleOutlookInterval, time.Until(lingerUntil)))
			continue
		}
		if err != nil {
			r.pause(time.Duration(r.backoff.Tick() * float64(time.Second)))
			continue
		}

		// A signal raced with the in-flight claim.
		if r.shuttingDown.Load() {
			r.logf("claimed job #%d after shutdown; reporting it canceled without starting", claim.ID)
			r.reportCanceled(claim.ID)
			break
		}

		r.backoff.Reset()
		r.runJob(ctx, claim)
		r.idleSince = time.Now()
		lingerUntil = time.Time{}
	}

	r.logf("forge-ci-runner stopped")
	return nil
}

// beginShutdown records the stopClaiming lifetime. Ordinary TERM lets the
// in-flight step finish; with REQUEUE_ON_SHUTDOWN the executor interrupts
// (its requeueCheck sees shuttingDown) and the job is released.
func (r *Runner) beginShutdown(sig os.Signal) {
	r.shutdownMu.Lock()
	defer r.shutdownMu.Unlock()
	if r.shuttingDown.Load() {
		return
	}
	if sig != nil {
		r.shutdownSignal = sig.String()
	}
	r.shuttingDown.Store(true)
	close(r.shutdownDone)
	plan := "finishing current job"
	if r.cfg.RequeueOnShutdown {
		plan = "releasing current job"
		if cancel, ok := r.execCancel.Load().(context.CancelFunc); ok && cancel != nil {
			cancel()
		}
	}
	r.logf("received %s; %s, no new claims", orDefault(r.shutdownSignal, "signal"), plan)
}

func (r *Runner) idleTooLong() bool {
	limit := r.cfg.IdleShutdownAfter
	if limit <= 0 {
		return false
	}
	return time.Since(r.idleSince) >= time.Duration(limit*float64(time.Second))
}

func seconds(value float64) time.Duration {
	return time.Duration(value * float64(time.Second))
}

func lingerPause(interval float64, remaining time.Duration) time.Duration {
	d := seconds(interval)
	if d <= 0 {
		d = 15 * time.Second
	}
	if remaining < d {
		return remaining
	}
	return d
}

// idleShutdown runs the scale-to-zero command (e.g. ASG self-terminate) and
// returns; Run then exits.
func (r *Runner) idleShutdown() {
	r.logf("idle for %ds; shutting down", int(r.cfg.IdleShutdownAfter))
	if r.cfg.IdleShutdownCommand == "" {
		return
	}
	r.logf("running IDLE_SHUTDOWN_COMMAND")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", r.cfg.IdleShutdownCommand)
	if err := cmd.Run(); err != nil {
		r.logf("IDLE_SHUTDOWN_COMMAND failed: %v", err)
	}
}

// pause sleeps for d, but a signal ends it early so shutdown is prompt.
func (r *Runner) pause(d time.Duration) {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-r.shutdownDone:
	case <-timer.C:
	}
}

// runJob executes one claimed job through its full lifecycle.
func (r *Runner) runJob(ctx context.Context, claim *payload.Claim) {
	r.logf("claimed job #%d (%s)", claim.ID, claim.Name)

	// Signal after claim but before start: report canceled immediately —
	// containers never come up, start is never sent.
	if r.shuttingDown.Load() {
		r.reportCanceled(claim.ID)
		return
	}

	if err := r.client.Start(ctx, claim.ID); err != nil {
		// e.g. 422: the job was reclaimed after our heartbeats died, or a
		// cancel raced the claim. Do not retry (not idempotent).
		r.logf("could not start job #%d: %v", claim.ID, err)
		return
	}

	// The execution context is the interruptExecution lifetime: canceled by
	// server-cancel or requeue shutdown, deadline-bounded by the executor.
	execCtx, cancelExec := context.WithCancel(context.Background())
	r.execCancel.Store(cancelExec)
	if r.shuttingDown.Load() && r.cfg.RequeueOnShutdown {
		cancelExec()
	}
	defer cancelExec()

	heartbeatDone := make(chan struct{})
	jobCanceled := make(chan struct{})
	var once sync.Once
	interruptForCancel := func() {
		once.Do(func() {
			close(jobCanceled)
			cancelExec() // stop in-flight docker ops promptly
		})
	}
	go r.heartbeatLoop(execCtx, claim.ID, heartbeatDone, interruptForCancel)

	exec := executor.New(r.cfg, r.client, claim)
	status, stepResults := exec.Execute(
		execCtx,
		func() bool { return r.shuttingDown.Load() }, // shutdownCheck
		func() bool {
			select {
			case <-jobCanceled:
				return true
			default:
				return false
			}
		}, // cancelCheck
	)
	// Executor drained its log stream before returning; terminal reporting
	// happens strictly after.
	interruptForCancel() // ensure the heartbeat goroutine stops (bounded)
	select {
	case <-heartbeatDone:
	case <-time.After(2 * time.Second):
		// An in-flight heartbeat during finalization: its result is
		// irrelevant now; don't wait for it.
	}

	finalCtx, cancelFinal := context.WithTimeout(context.Background(), api.JSONDeadline())
	defer cancelFinal()
	ctx = finalCtx
	switch status {
	case executor.StatusRequeue:
		r.releaseJob(ctx, claim.ID, stepResults)
	case executor.StatusCanceled:
		// Server-driven cancel or ordinary shutdown after a finished step.
		if err := r.client.Complete(ctx, claim.ID, "canceled", stepResults); err != nil {
			r.logf("could not report job #%d: %v", claim.ID, err)
		} else {
			r.logf("job #%d canceled", claim.ID)
		}
	case executor.StatusFailed, executor.StatusSuccess:
		if err := r.client.Complete(ctx, claim.ID, status, stepResults); err != nil {
			r.logf("could not report job #%d: %v", claim.ID, err)
		} else {
			r.logf("job #%d %s", claim.ID, status)
		}
	default:
		r.logf("job #%d unknown status %q; reporting failed", claim.ID, status)
		_ = r.client.Complete(ctx, claim.ID, "failed", stepResults)
	}
}

// heartbeatLoop refreshes heartbeat_at while the job runs and watches for
// the control plane canceling it. Bounded by execCtx so an in-flight
// heartbeat cannot outlive the job.
func (r *Runner) heartbeatLoop(ctx context.Context, jobID int64, done chan struct{}, onCanceled func()) {
	defer close(done)
	ticker := time.NewTicker(time.Duration(r.cfg.HeartbeatInterval * float64(time.Second)))
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		hbCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		reply, err := r.client.Heartbeat(hbCtx, jobID)
		cancel()
		if err != nil {
			r.logf("heartbeat failed for job #%d: %v", jobID, err)
			continue
		}
		if reply != nil && reply.Status == "canceled" {
			r.logf("job #%d was canceled by the control plane; stopping", jobID)
			onCanceled()
			return
		}
	}
}

// releaseJob hands the job back to the queue (requeue shutdown). The
// response does not matter for local execution — it is already stopped —
// but a refused or unreachable release must fall back to reporting the job
// canceled so the server does not wait on a runner that left.
func (r *Runner) releaseJob(ctx context.Context, jobID int64, stepResults []api.StepResult) {
	r.shutdownMu.Lock()
	reason := fmt.Sprintf("runner shutting down (%s)", orDefault(r.shutdownSignal, "signal"))
	r.shutdownMu.Unlock()
	err := r.client.Release(ctx, jobID, reason)
	if err == nil {
		r.logf("job #%d released back to the queue", jobID)
		return
	}
	r.logf("could not release job #%d (%v); reporting it canceled", jobID, err)
	if cerr := r.client.Complete(ctx, jobID, "canceled", stepResults); cerr != nil {
		r.logf("could not report job #%d: %v", jobID, cerr)
	} else {
		r.logf("job #%d canceled", jobID)
	}
}

// reportCanceled completes a claimed-but-not-started job as canceled
// (bounded, own context: usable after shutdown).
func (r *Runner) reportCanceled(jobID int64) {
	ctx, cancel := context.WithTimeout(context.Background(), api.JSONDeadline())
	defer cancel()
	if err := r.client.Complete(ctx, jobID, "canceled", nil); err != nil {
		r.logf("could not report job #%d: %v", jobID, err)
	} else {
		r.logf("job #%d canceled", jobID)
	}
}

func (r *Runner) logf(format string, args ...any) {
	r.logMu.Lock()
	defer r.logMu.Unlock()
	fmt.Fprintf(os.Stderr, "[forge-ci-runner] "+format+"\n", args...)
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}
