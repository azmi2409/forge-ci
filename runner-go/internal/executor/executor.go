// Package executor executes one claimed job in Docker containers.
//
// Lifecycle per job:
//  1. pull primary + service images, create an isolated network
//  2. start service containers, then the primary (long-lived) container
//  3. run each step via docker exec, streaming redacted logs
//  4. ALWAYS clean up containers + network (deferred, bounded)
//
// The docker CLI is invoked with argv arrays (no shell interpolation).
// Steps share the primary container's filesystem, so intra-job state just
// works. Every docker operation runs under the job context (deadline +
// interrupt); cleanup runs under its own bounded context so shutdown cannot
// hang. The host target is Linux; darwin builds exist for tests only.
package executor

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/logstream"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
	"github.com/azmi2409/forge-ci/runner-go/internal/planner"
	"github.com/azmi2409/forge-ci/runner-go/internal/redact"
)

//go:embed scripts/circleci_cli.sh
var circleCLIScript []byte

//go:embed scripts/docker_build_wrapper.sh
var buildWrapperScript []byte

const (
	circleCLIFile    = "circleci_cli.sh"
	buildWrapperFile = "docker_build_wrapper.sh"
)

// ControlPlane is the slice of the control-plane client the executor uses.
// Production passes *api.Client; tests pass fakes.
type ControlPlane interface {
	PutCache(ctx context.Context, projectID int64, key, tarballPath string) (*api.CacheHit, error)
	GetCache(ctx context.Context, projectID int64, keys []string) (*api.CacheHit, error)
	PostArtifact(ctx context.Context, jobID int64, localPath, path, destination string) (*api.ArtifactInfo, error)
	Download(ctx context.Context, rawURL, destPath string) error
	// PostLogChunk feeds the log streamer (idempotent upsert server-side).
	PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error
}

// Executor owns one job run. Construct with New, then Execute.
type Executor struct {
	cfg    *config.Config
	client ControlPlane
	claim  *payload.Claim

	// Interruption checks, wired by Execute (no-ops before that).
	cancelCheck  func() bool
	requeueCheck func() bool

	jobID             int64
	suffix            string
	container         string
	network           string
	buildxBuilderName string
	workflowID        *int64
	projectID         *int64

	redactor *redact.Redactor
	streamer *logstream.Streamer

	defaultShell string
	// runCtx bounds every docker operation of this job: it carries the job
	// deadline and is canceled on interrupt (requeue shutdown / cancel).
	runCtx    context.Context
	runCancel context.CancelFunc

	services          []string
	buildxCreated     bool
	stoppedForRequeue bool

	mu       sync.Mutex
	stepsDir string
}

// Statuses returned by Execute (requeue is internal: the runner releases
// instead of completing).
const (
	StatusSuccess  = "success"
	StatusFailed   = "failed"
	StatusCanceled = "canceled"
	StatusRequeue  = "requeue"
)

// New builds an executor for a claimed job. The redactor covers the job
// environment plus the checkout token and build-cache password (steps must
// never see the token; the build-cache password is seen but never logged).
func New(cfg *config.Config, client ControlPlane, claim *payload.Claim) *Executor {
	jobID := claim.ID
	suffix := randHex(4)
	e := &Executor{
		cfg:               cfg,
		client:            client,
		claim:             claim,
		jobID:             jobID,
		suffix:            suffix,
		container:         "forge-ci-job-" + strconv.FormatInt(jobID, 10) + "-" + suffix,
		network:           "forge-ci-net-" + strconv.FormatInt(jobID, 10) + "-" + suffix,
		buildxBuilderName: "forge-ci-bx-" + strconv.FormatInt(jobID, 10) + "-" + suffix,
		defaultShell:      posixShell,
		workflowID:        claim.WorkflowRunID,
		projectID:         claim.ProjectID,
	}
	checkoutToken := ""
	if claim.Repository != nil && claim.Repository.Token != nil {
		checkoutToken = *claim.Repository.Token
	}
	buildCachePassword := ""
	if claim.DockerBuildCache != nil && claim.DockerBuildCache.Password != nil {
		buildCachePassword = *claim.DockerBuildCache.Password
	}
	env := claim.Environment.Merge(payload.Env{
		"__checkout_token":       checkoutToken,
		"__build_cache_password": buildCachePassword,
	})
	e.redactor = redact.New(env, cfg.RedactMinLength)
	e.streamer = logstream.New(client, jobID, e.redactor, cfg.LogChunkSize, time.Duration(cfg.LogFlushInterval*float64(time.Second)))
	return e
}

// Execute runs the job. shutdownCheck is the runner's "shutting down" flag
// (finish the in-flight step, skip the rest — ordinary TERM), cancelCheck is
// the control plane's cancel flag. With requeue-on-shutdown configured, a
// shutdown instead interrupts the current step; an unfinished job returns
// StatusRequeue (the runner releases it rather than completing).
func (e *Executor) Execute(shutdownCheck func() bool, cancelCheck func() bool) (string, []api.StepResult) {
	requeueCheck := func() bool { return false }
	if e.cfg.RequeueOnShutdown {
		requeueCheck = shutdownCheck
	}

	// Job deadline bounds everything, including pulls and transfers.
	base := context.Background()
	if e.cfg.JobTimeout > 0 {
		var cancel context.CancelFunc
		base, cancel = context.WithTimeout(base, time.Duration(e.cfg.JobTimeout*float64(time.Second)))
		defer cancel()
	}
	e.runCtx, e.runCancel = context.WithCancel(base)
	defer e.runCancel()

	e.cancelCheck = cancelCheck
	e.requeueCheck = func() bool { return false }
	if e.cfg.RequeueOnShutdown {
		e.requeueCheck = shutdownCheck
	}

	e.streamer.StartTimer()
	defer e.streamer.Close()
	defer e.cleanup()

	results := []api.StepResult{}
	failed := false
	shuttingDown := false

	e.logf("[forge-ci] starting job #%d (%s, sha=%s)", e.jobID, e.claim.Name, e.claim.Pipeline.SHA)

	// Extract embedded helpers once per job (docker cp needs host files);
	// private 0700 dir, removed at cleanup.
	if err := e.unpackScripts(); err != nil {
		e.logf("[forge-ci] ERROR: %v", err)
		return StatusFailed, results
	}

	setupErr := func() error {
		if err := e.checkRemoteDocker(); err != nil {
			return err
		}
		return e.setupContainers()
	}()
	if setupErr != nil {
		if errors.Is(setupErr, errInterrupted) || e.runCtx.Err() != nil {
			e.logf("[forge-ci] setup interrupted: %v", setupErr)
		} else {
			e.logf("[forge-ci] ERROR: %v", setupErr)
		}
		failed = true
	}

	if setupErr == nil {
		for _, entry := range planner.Plan(e.claim.Steps) {
			if shutdownCheck() || cancelCheck() {
				shuttingDown = true
				note := "runner shutting down"
				if cancelCheck() {
					note = "job canceled"
				}
				results = append(results, e.skippedResult(entry, note))
				continue
			}
			if !planner.Runnable(entry.Step, failed) {
				results = append(results, e.skippedResult(entry,
					fmt.Sprintf("when=%s not satisfied", entry.Step.When)))
				continue
			}
			result := e.executeStep(entry)
			results = append(results, result)
			if result.ExitCode != 0 {
				failed = true
			}
		}
	}

	if e.runCtx.Err() != nil && errors.Is(e.runCtx.Err(), context.DeadlineExceeded) {
		failed = true
	}

	switch {
	case requeueCheck() && (shuttingDown || e.stoppedForRequeue):
		return StatusRequeue, results
	case shuttingDown || cancelCheck():
		return StatusCanceled, results
	case failed:
		return StatusFailed, results
	default:
		return StatusSuccess, results
	}
}

// Streamer exposes the job's log stream (the runner drains it before
// reporting terminal status).
func (e *Executor) Streamer() *logstream.Streamer { return e.streamer }

// Cancel interrupts in-flight docker operations (setup, transfers, and the
// current step's watchdog). Used by the runner for server-driven cancels.
func (e *Executor) Cancel() {
	if e.runCancel != nil {
		e.runCancel()
	}
}

func (e *Executor) cancelCheckFired() bool {
	return e.cancelCheck != nil && e.cancelCheck()
}

func (e *Executor) requeueCheckFired() bool {
	return e.requeueCheck != nil && e.requeueCheck()
}

// logf writes a runner-authored line into the job log.
func (e *Executor) logf(format string, args ...any) {
	e.streamer.Write([]byte(fmt.Sprintf(format+"\n", args...)))
}

// unpackScripts writes the embedded shell helpers to a private temp dir.
func (e *Executor) unpackScripts() error {
	dir, err := os.MkdirTemp("", "forge-ci-scripts-")
	if err != nil {
		return fmt.Errorf("script temp dir: %w", err)
	}
	e.mu.Lock()
	e.stepsDir = dir
	e.mu.Unlock()
	for name, content := range map[string][]byte{
		circleCLIFile:    circleCLIScript,
		buildWrapperFile: buildWrapperScript,
	} {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, content, 0o755); err != nil {
			return fmt.Errorf("write %s: %w", name, err)
		}
	}
	return nil
}

// cleanup removes containers, the buildkit container, the network, and the
// script temp dir — under its own bounded context so shutdown cannot hang.
func (e *Executor) cleanup() {
	ctx, cancel := context.WithTimeout(context.Background(), cleanupBudget)
	defer cancel()

	names := append([]string{e.container}, e.services...)
	if e.buildxCreated {
		names = append(names, e.buildxBuilderContainer())
	}
	for _, name := range names {
		if _, err := runStream(ctx, []string{e.cfg.DockerBin, "rm", "-f", name}, func([]byte) {}); err != nil {
			fmt.Fprintf(os.Stderr, "[forge-ci-runner] cleanup: rm -f %s failed: %v\n", name, err)
		}
	}
	if _, err := runStream(ctx, []string{e.cfg.DockerBin, "network", "rm", e.network}, func([]byte) {}); err != nil {
		fmt.Fprintf(os.Stderr, "[forge-ci-runner] cleanup: network rm failed: %v\n", err)
	}
	e.mu.Lock()
	dir := e.stepsDir
	e.mu.Unlock()
	if dir != "" {
		os.RemoveAll(dir)
	}
}

// --- container setup ---------------------------------------------------------

func (e *Executor) checkRemoteDocker() error {
	if !e.remoteDocker() {
		return nil
	}
	if !e.cfg.AllowDockerSocket {
		return errors.New("this job uses setup_remote_docker, which this runner doesn't allow. " +
			"Only runners trusted with their host's Docker (like a deploy runner) set ALLOW_DOCKER_SOCKET=1")
	}
	if !e.claim.TrustedPipeline() {
		return errors.New("setup_remote_docker isn't available to pull requests from forks")
	}
	return nil
}

func (e *Executor) setupContainers() error {
	ex := e.claim.Executor
	if ex == nil {
		return fmt.Errorf("job payload is missing executor")
	}
	images := []string{ex.Image}
	for _, svc := range ex.SecondaryImages {
		images = append(images, svc.Image)
	}
	seen := map[string]bool{}
	for _, image := range images {
		if image == "" || seen[image] {
			continue
		}
		seen[image] = true
		e.logf("[forge-ci] pulling %s ...", image)
		res, err := runStream(e.runCtx, []string{e.cfg.DockerBin, "pull", image}, e.streamLog)
		if err != nil {
			return fmt.Errorf("docker pull %s: %w", image, err)
		}
		if res.exitCode != 0 {
			return fmt.Errorf("docker pull %s failed (exit %d)", image, res.exitCode)
		}
	}

	e.logf("[forge-ci] creating network %s", e.network)
	if res, err := e.runLogged(e.cfg.DockerBin, "network", "create", e.network); err != nil || res.exitCode != 0 {
		return fmt.Errorf("docker network create failed (exit %d): %w", res.exitCode, err)
	}

	for i, svc := range ex.SecondaryImages {
		name, args := e.serviceRunArgs(svc, i)
		e.logf("[forge-ci] starting service %s (%s)", name, svc.Image)
		res, err := runStream(e.runCtx, args, e.streamLog)
		if err != nil {
			return fmt.Errorf("service %s failed to start: %w", name, err)
		}
		if res.exitCode != 0 {
			return fmt.Errorf("service %s failed to start (exit %d)", name, res.exitCode)
		}
		e.services = append(e.services, name)
	}

	e.logf("[forge-ci] starting primary container %s (%s)", e.container, ex.Image)
	args, err := e.primaryRunArgs()
	if err != nil {
		return err
	}
	res, err := runStream(e.runCtx, args, e.streamLog)
	if err != nil {
		return fmt.Errorf("primary container failed to start: %w", err)
	}
	if res.exitCode != 0 {
		return fmt.Errorf("primary container failed to start (exit %d)", res.exitCode)
	}

	if err := e.prepareShell(); err != nil {
		return err
	}
	e.installCircleCLI()
	return nil
}

// streamLog routes command output into the job log.
func (e *Executor) streamLog(p []byte) { e.streamer.Write(p) }

// runLogged runs a docker op streaming output to the job log.
func (e *Executor) runLogged(args ...string) (runResult, error) {
	return runStream(e.runCtx, args, e.streamLog)
}

// prepareShell picks the default `run` shell (bash when the image has it,
// like CircleCI) and creates the empty $BASH_ENV file.
func (e *Executor) prepareShell() error {
	res, err := runCapture(e.runCtx, []string{
		e.cfg.DockerBin, "exec", e.container, "/bin/sh", "-c",
		"touch " + bashEnvPath + " && test -x /bin/bash",
	})
	if err == nil && res.exitCode == 0 {
		e.defaultShell = bashShell
	}
	return nil
}

// installCircleCLI copies the `circleci tests` helper into the container.
// A failure only costs test splitting, so it warns instead of failing.
func (e *Executor) installCircleCLI() {
	res, err := e.runLogged(e.cfg.DockerBin, "cp", e.scriptPath(circleCLIFile), e.container+":"+circlecliIn)
	if err != nil || res.exitCode != 0 {
		e.logf("[forge-ci] WARNING: could not install %s; `circleci tests` won't be available", circlecliIn)
	}
}

// sha256Inside computes the SHA256 of a file inside the container (path
// relative to the workdir). Empty when missing/unreadable — silent, query
// output must not pollute the job log.
func (e *Executor) sha256Inside(relativePath string) string {
	target := e.workdir() + "/" + relativePath
	ctx, cancel := context.WithTimeout(e.runCtx, 30*time.Second)
	defer cancel()
	res, err := runCapture(ctx, []string{e.cfg.DockerBin, "exec", e.container, "sha256sum", "--", target})
	if err != nil || res.exitCode != 0 {
		return ""
	}
	fields := strings.Fields(res.output)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// scriptPath returns the host path of an unpacked embedded helper.
func (e *Executor) scriptPath(name string) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return filepath.Join(e.stepsDir, name)
}

// ScriptDir exposes the unpacked-helpers directory (tests assert it is
// removed after the run; it is not for external use).
func (e *Executor) ScriptDir() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stepsDir
}
