package executor

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/keytemplate"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
	"github.com/azmi2409/forge-ci/runner-go/internal/planner"
	"github.com/azmi2409/forge-ci/runner-go/internal/tarutil"
)

// Exit codes matching the Ruby runner / CircleCI conventions.
const (
	timeoutExit = 124
	cancelExit  = 130
)

// deferred steps have no implementation yet: skipped loudly, never failed —
// failing here would be lying about the job.
var deferredSteps = map[string]bool{
	"store_test_results": true,
	"add_ssh_keys":       true,
}

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "0000000000"[:n*2]
	}
	return hex.EncodeToString(b)
}

func socketGID(path string) (int, bool) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, false
	}
	if stat, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int(stat.Gid), true
	}
	return 0, false
}

// executeStep runs one step and records its result.
func (e *Executor) executeStep(entry planner.Entry) api.StepResult {
	started := time.Now().UTC().Format(time.RFC3339)
	e.logf("--- step: %s (%s) ---", entry.Name, entry.Step.Type)
	t0 := time.Now()

	exitCode := e.dispatch(entry.Step)

	e.logf("--- step finished: %s (exit %d, %.1fs) ---", entry.Name, exitCode, time.Since(t0).Seconds())
	return api.StepResult{
		Name:       entry.Name,
		ExitCode:   exitCode,
		StartedAt:  started,
		FinishedAt: time.Now().UTC().Format(time.RFC3339),
	}
}

func (e *Executor) dispatch(step *payload.Step) int {
	switch step.Type {
	case "run":
		return e.executeRun(step)
	case "checkout":
		return e.executeCheckout(step)
	case "save_cache":
		return e.executeSaveCache(step)
	case "restore_cache":
		return e.executeRestoreCache(step)
	case "store_artifacts":
		return e.executeStoreArtifacts(step)
	case "persist_to_workspace":
		return e.executePersistWorkspace(step)
	case "attach_workspace":
		return e.executeAttachWorkspace(step)
	case "setup_remote_docker":
		return e.executeSetupRemoteDocker(step)
	default:
		if deferredSteps[step.Type] {
			e.logf("[forge-ci] WARNING: %s is not implemented yet — skipping loudly, not failing the job.", step.Type)
			return 0
		}
		e.logf("[forge-ci] WARNING: unknown step type %q; skipping", step.Type)
		return 0
	}
}

func (e *Executor) skippedResult(entry planner.Entry, note string) api.StepResult {
	e.logf("--- step skipped: %s (%s) ---", entry.Name, note)
	now := time.Now().UTC().Format(time.RFC3339)
	return api.StepResult{Name: entry.Name, ExitCode: 0, StartedAt: now, FinishedAt: now}
}

// --- run ---------------------------------------------------------------------

func (e *Executor) executeRun(step *payload.Step) int {
	if step.Background {
		res, err := runStream(e.runCtx, e.execArgs(step, true), e.streamLog)
		if err != nil {
			return 1
		}
		e.logf("[forge-ci] background step launched (exit %d)", res.exitCode)
		return res.exitCode
	}
	timeout := e.cfg.StepNoOutputTimeout
	if step.NoOutputTimeout != nil {
		if parsed := parseDuration(*step.NoOutputTimeout); parsed > 0 {
			timeout = parsed
		}
	}
	return e.streamStep(e.execArgs(step, false), timeout)
}

// streamStep runs a docker exec with the interruption watchdog: server
// cancel or requeue-shutdown stop it (130), silence past noOutputTimeout or
// the job deadline stop it (124). Ordinary shutdown does NOT interrupt —
// the in-flight step finishes (matching the Ruby runner).
func (e *Executor) streamStep(argv []string, noOutputTimeout float64) int {
	cmd, waitCh, err := startStreamed(argv, e.streamLog)
	if err != nil {
		e.logf("[forge-ci] ERROR: %v", err)
		return 1
	}

	ticker := time.NewTicker(watchdogTick)
	defer ticker.Stop()
	fired := false
	for !fired {
		select {
		case werr := <-waitCh:
			return exitOf(werr, cmd)
		case <-ticker.C:
			if e.cancelCheckFired() || e.requeueCheckFired() {
				fired = true
			} else if noOutputTimeout > 0 && time.Since(e.streamer.LastWrite()) > time.Duration(noOutputTimeout*float64(time.Second)) {
				fired = true
			} else if dl, ok := e.runCtx.Deadline(); ok && !time.Now().Before(dl) {
				fired = true
			}
		case <-e.runCtx.Done():
			fired = true
		}
	}

	terminateGroup(cmd.Process.Pid)
	<-waitCh // reap; output copier bounded by WaitDelay

	switch {
	case e.cancelCheckFired():
		e.logf("[forge-ci] step stopped: job was canceled")
		return cancelExit
	case e.requeueCheckFired():
		e.logf("[forge-ci] step stopped: runner shutting down; the job goes back to the queue")
		e.mu.Lock()
		e.stoppedForRequeue = true
		e.mu.Unlock()
		return cancelExit
	case e.runCtx.Err() == context.Canceled:
		e.logf("[forge-ci] step stopped: job context canceled")
		return cancelExit
	case noOutputTimeout > 0 && time.Since(e.streamer.LastWrite()) > time.Duration(noOutputTimeout*float64(time.Second)):
		e.logf("[forge-ci] step killed: no output for %ds (no_output_timeout)", int(noOutputTimeout))
		return timeoutExit
	default:
		if dl, ok := e.runCtx.Deadline(); ok && !time.Now().Before(dl) {
			e.logf("[forge-ci] step killed: job exceeded %ds (JOB_TIMEOUT)", int(e.cfg.JobTimeout))
		} else {
			e.logf("[forge-ci] step stopped: job context ended")
		}
		return timeoutExit
	}
}

// --- checkout ------------------------------------------------------------------

func (e *Executor) executeCheckout(step *payload.Step) int {
	repoURL := e.cfg.CheckoutRepoURL
	sha := e.claim.Pipeline.SHA
	if e.claim.Repository != nil {
		if e.claim.Repository.URL != "" {
			repoURL = e.claim.Repository.URL
		}
		if e.claim.Repository.SHA != nil && *e.claim.Repository.SHA != "" {
			sha = *e.claim.Repository.SHA
		}
	}
	if repoURL == "" {
		e.logf("[forge-ci] WARNING: skipping checkout — no repository.url in the claim payload " +
			"and CHECKOUT_REPO_URL is not set.")
		return 0
	}
	token := ""
	if e.claim.Repository != nil && e.claim.Repository.Token != nil {
		token = *e.claim.Repository.Token
	}

	target := e.workdir()
	if step.Path != nil && *step.Path != "" {
		target = filepath.Join(target, *step.Path)
	}
	script, tokenEnv := checkoutScript(e.workdir(), target, repoURL, sha, token)
	e.logf("[forge-ci] cloning %s @ %s", stripUserinfo(repoURL), sha)

	argv := []string{e.cfg.DockerBin, "exec"}
	argv = append(argv, tokenEnv...)
	argv = append(argv, e.container, "/bin/sh", "-c", script)
	return e.streamStep(argv, e.cfg.StepNoOutputTimeout)
}

// --- cache / artifacts / workspaces -----------------------------------------------

// warnZero logs a warning and exits the step successfully (cache/artifact
// problems must never fail the job — the Ruby runner's contract).
func (e *Executor) warnZero(format string, args ...any) int {
	e.logf("[forge-ci] WARNING: "+format, args...)
	return 0
}

func (e *Executor) requireProjectID(stepType string) bool {
	if e.projectID != nil {
		return true
	}
	e.logf("[forge-ci] WARNING: skipping %s — the claim payload carries no project_id, so the "+
		"cache API cannot be addressed. (The control plane should include project_id in the job payload.)", stepType)
	return false
}

func (e *Executor) requireWorkflowID(stepType string) bool {
	if e.workflowID != nil {
		return true
	}
	e.logf("[forge-ci] WARNING: skipping %s — no workflow_run_id in payload; skipping", stepType)
	return false
}

func (e *Executor) resolveKey(template string) string {
	var warns []string
	key := keytemplate.Resolve(template, keytemplate.Options{
		Branch:   derefString(e.claim.Pipeline.Branch),
		Checksum: e.sha256Inside,
		Warn:     func(m string) { warns = append(warns, m) },
	})
	for _, w := range warns {
		e.logf("[forge-ci] WARNING: cache key: %s", w)
	}
	return key
}

func (e *Executor) cpFromContainer(containerPath, hostPath string) error {
	res, err := e.runLogged(e.cfg.DockerBin, "cp", e.container+":"+containerPath, hostPath)
	if err != nil {
		return err
	}
	if res.exitCode != 0 {
		return fmt.Errorf("docker cp from container failed (exit %d)", res.exitCode)
	}
	return nil
}

func (e *Executor) cpToContainer(hostPath, containerPath string) error {
	res, err := e.runLogged(e.cfg.DockerBin, "cp", hostPath, e.container+":"+containerPath)
	if err != nil {
		return err
	}
	if res.exitCode != 0 {
		return fmt.Errorf("docker cp to container failed (exit %d)", res.exitCode)
	}
	return nil
}

func (e *Executor) containerTemp(prefix string) string {
	return "/tmp/forge-ci-" + prefix + "-" + randHex(6) + ".tgz"
}

func (e *Executor) rmInsideContainer(path string) {
	e.runLogged(e.cfg.DockerBin, "exec", e.container, "rm", "-f", path)
}

func (e *Executor) executeSaveCache(step *payload.Step) int {
	if !e.requireProjectID("save_cache") {
		return 0
	}
	key := ""
	if len(step.Keys) > 0 {
		key = e.resolveKey(step.Keys[0])
	}
	if key == "" {
		return e.warnZero("save_cache has no usable key; skipping")
	}
	paths := nonEmpty(step.Paths)
	if len(paths) == 0 {
		return e.warnZero("save_cache has no paths; skipping")
	}

	containerTgz := e.containerTemp("cache")
	res, err := e.runLogged(e.tarCreateArgs(containerTgz, paths, e.workdir())...)
	if err != nil || res.exitCode != 0 {
		return e.warnZero("save_cache: tar of cache paths failed (exit %d)", res.exitCode)
	}

	hostDir, err := os.MkdirTemp("", "forge-ci-cache-")
	if err != nil {
		return e.warnZero("save_cache: %v", err)
	}
	hostTgz := filepath.Join(hostDir, "cache.tgz")
	defer os.RemoveAll(hostDir)
	defer e.rmInsideContainer(containerTgz)

	if err := e.cpFromContainer(containerTgz, hostTgz); err != nil {
		return e.warnZero("save_cache failed: %v", err)
	}
	hit, err := e.client.PutCache(e.uploadCtx(), *e.projectID, key, hostTgz)
	if err != nil {
		return e.warnZero("save_cache failed: %v", err)
	}
	e.logf("[forge-ci] save_cache: stored key %s (%d bytes)", hit.Key, hit.Size)
	return 0
}

func (e *Executor) executeRestoreCache(step *payload.Step) int {
	if !e.requireProjectID("restore_cache") {
		return 0
	}
	keys := nonEmpty(step.Keys)
	if len(keys) == 0 {
		return e.warnZero("restore_cache has no keys; skipping")
	}
	resolved := make([]string, 0, len(keys))
	for _, k := range keys {
		if r := e.resolveKey(k); r != "" {
			resolved = append(resolved, r)
		}
	}
	e.logf("[forge-ci] restore_cache: trying %s", strings.Join(resolved, ", "))

	hit, err := e.client.GetCache(e.uploadCtx(), derefInt64(e.projectID), resolved)
	if err != nil {
		return e.warnZero("restore_cache failed: %v", err)
	}
	if hit == nil || hit.DownloadURL == "" {
		e.logf("[forge-ci] restore_cache: no matching cache entry (miss).")
		return 0
	}

	hostDir, err := os.MkdirTemp("", "forge-ci-cache-")
	if err != nil {
		return e.warnZero("restore_cache: %v", err)
	}
	hostTgz := filepath.Join(hostDir, "cache.tgz")
	defer os.RemoveAll(hostDir)
	if err := e.client.Download(e.uploadCtx(), hit.DownloadURL, hostTgz); err != nil {
		return e.warnZero("restore_cache: download failed: %v", err)
	}

	containerTgz := e.containerTemp("cache")
	defer e.rmInsideContainer(containerTgz)
	if err := e.cpToContainer(hostTgz, containerTgz); err != nil {
		return e.warnZero("restore_cache failed: %v", err)
	}
	res, err := e.runLogged(e.tarExtractArgs(containerTgz, e.workdir())...)
	if err != nil || res.exitCode != 0 {
		return e.warnZero("restore_cache: extract failed (exit %d)", res.exitCode)
	}
	e.logf("[forge-ci] restore_cache: hit, extracted into %s", e.workdir())
	return 0
}

func (e *Executor) executeStoreArtifacts(step *payload.Step) int {
	src := derefString(step.Path)
	if src == "" {
		return e.warnZero("store_artifacts has no path; skipping")
	}
	destination := derefString(step.Destination)

	containerTgz := e.containerTemp("artifacts")
	res, err := e.runLogged(e.tarCreateArgs(containerTgz, []string{src}, e.workdir())...)
	if err != nil || res.exitCode != 0 {
		return e.warnZero("store_artifacts: could not archive %s (exit %d)", src, res.exitCode)
	}
	defer e.rmInsideContainer(containerTgz)

	hostDir, err := os.MkdirTemp("", "forge-ci-artifacts-")
	if err != nil {
		return e.warnZero("store_artifacts: %v", err)
	}
	defer os.RemoveAll(hostDir)
	hostTgz := filepath.Join(hostDir, "archive.tgz")
	if err := e.cpFromContainer(containerTgz, hostTgz); err != nil {
		return e.warnZero("store_artifacts failed: %v", err)
	}
	filesDir := filepath.Join(hostDir, "files")
	if err := tarutil.Extract(e.uploadCtx(), hostTgz, filesDir); err != nil {
		return e.warnZero("store_artifacts: unpack failed: %v", err)
	}
	var files []string
	filepath.Walk(filesDir, func(path string, info os.FileInfo, err error) error {
		if err == nil && info.Mode().IsRegular() {
			files = append(files, path)
		}
		return nil
	})
	if len(files) == 0 {
		return e.warnZero("store_artifacts: nothing found at %s", src)
	}
	for _, f := range files {
		rel, err := filepath.Rel(filesDir, f)
		if err != nil {
			continue
		}
		info, err := e.client.PostArtifact(e.uploadCtx(), e.jobID, f, rel, destination)
		if err != nil {
			return e.warnZero("store_artifacts upload of %s failed: %v", rel, err)
		}
		suffix := ""
		if destination != "" {
			suffix = " -> " + destination
		}
		e.logf("[forge-ci] artifact stored: %s%s (%d bytes)", rel, suffix, info.Size)
	}
	return 0
}

// --- workspaces ---------------------------------------------------------------

func (e *Executor) workspaceManifest() []string {
	if e.projectID == nil {
		return nil
	}
	hit, err := e.client.GetCache(e.uploadCtx(), *e.projectID, []string{e.workspaceManifestKey()})
	if err != nil || hit == nil || hit.DownloadURL == "" {
		return nil
	}
	dir, err := os.MkdirTemp("", "forge-ci-ws-manifest-")
	if err != nil {
		return nil
	}
	defer os.RemoveAll(dir)
	dest := filepath.Join(dir, "manifest.json")
	if err := e.client.Download(e.uploadCtx(), hit.DownloadURL, dest); err != nil {
		e.logf("[forge-ci] WARNING: workspace manifest unreadable (%v); starting fresh", err)
		return nil
	}
	b, err := os.ReadFile(dest)
	if err != nil {
		return nil
	}
	var roots []string
	if json.Unmarshal(b, &roots) != nil {
		e.logf("[forge-ci] WARNING: workspace manifest unreadable; starting fresh")
		return nil
	}
	return roots
}

func (e *Executor) saveWorkspaceManifest(roots []string) {
	dir, err := os.MkdirTemp("", "forge-ci-ws-manifest-")
	if err != nil {
		return
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "manifest.json")
	b, _ := json.Marshal(roots)
	if os.WriteFile(path, b, 0o644) != nil {
		return
	}
	e.client.PutCache(e.uploadCtx(), *e.projectID, e.workspaceManifestKey(), path)
}

func (e *Executor) executePersistWorkspace(step *payload.Step) int {
	if !e.requireProjectID("persist_to_workspace") || !e.requireWorkflowID("persist_to_workspace") {
		return 0
	}
	root := derefString(step.Root)
	paths := nonEmpty(step.Paths)
	if root == "" || len(paths) == 0 {
		return e.warnZero("persist_to_workspace needs root and paths; skipping")
	}
	baseDir := filepath.Join(e.workdir(), root)
	containerTgz := e.containerTemp("ws")
	res, err := e.runLogged(e.tarCreateArgs(containerTgz, paths, baseDir)...)
	if err != nil || res.exitCode != 0 {
		return e.warnZero("persist_to_workspace: tar failed (exit %d)", res.exitCode)
	}
	defer e.rmInsideContainer(containerTgz)

	hostDir, err := os.MkdirTemp("", "forge-ci-ws-")
	if err != nil {
		return e.warnZero("persist_to_workspace: %v", err)
	}
	defer os.RemoveAll(hostDir)
	hostTgz := filepath.Join(hostDir, "root.tgz")
	if err := e.cpFromContainer(containerTgz, hostTgz); err != nil {
		return e.warnZero("persist_to_workspace failed: %v", err)
	}
	key := workspaceRootKey(*e.workflowID, root)
	hit, err := e.client.PutCache(e.uploadCtx(), *e.projectID, key, hostTgz)
	if err != nil {
		return e.warnZero("persist_to_workspace failed: %v", err)
	}
	e.saveWorkspaceManifest(append(e.workspaceManifest(), root))
	e.logf("[forge-ci] persist_to_workspace: stored %s as %s (%d bytes)",
		strings.Join(paths, ", "), hit.Key, hit.Size)
	return 0
}

func (e *Executor) executeAttachWorkspace(step *payload.Step) int {
	if !e.requireProjectID("attach_workspace") || !e.requireWorkflowID("attach_workspace") {
		return 0
	}
	at := derefString(step.At)
	if at == "" {
		return e.warnZero("attach_workspace needs an 'at' path; skipping")
	}
	roots := e.workspaceManifest()
	if len(roots) == 0 {
		e.logf("[forge-ci] attach_workspace: workspace is empty; nothing to attach.")
		return 0
	}
	destBase := filepath.Join(e.workdir(), at)
	e.runLogged(e.cfg.DockerBin, "exec", e.container, "mkdir", "-p", destBase)

	for _, root := range roots {
		key := workspaceRootKey(*e.workflowID, root)
		hit, err := e.client.GetCache(e.uploadCtx(), *e.projectID, []string{key})
		if err != nil || hit == nil || hit.DownloadURL == "" {
			e.logf("[forge-ci] WARNING: attach_workspace: missing tarball for root %q; skipping it.", root)
			continue
		}
		hostDir, err := os.MkdirTemp("", "forge-ci-ws-")
		if err != nil {
			continue
		}
		hostTgz := filepath.Join(hostDir, "root.tgz")
		if dlErr := e.client.Download(e.uploadCtx(), hit.DownloadURL, hostTgz); dlErr != nil {
			os.RemoveAll(hostDir)
			e.logf("[forge-ci] WARNING: attach_workspace: download of %s failed: %v", root, dlErr)
			continue
		}
		containerTgz := e.containerTemp("ws")
		cpErr := e.cpToContainer(hostTgz, containerTgz)
		if cpErr == nil {
			res, exErr := e.runLogged(e.tarExtractArgs(containerTgz, destBase)...)
			if exErr == nil && res.exitCode == 0 {
				e.logf("[forge-ci] attach_workspace: attached %s at %s", root, at)
			} else {
				e.logf("[forge-ci] WARNING: attach_workspace: extract of %s failed (exit %d)", root, res.exitCode)
			}
			e.rmInsideContainer(containerTgz)
		} else {
			e.logf("[forge-ci] WARNING: attach_workspace: copy of %s failed: %v", root, cpErr)
		}
		os.RemoveAll(hostDir)
	}
	return 0
}

// --- setup_remote_docker / layer cache ------------------------------------------

func (e *Executor) executeSetupRemoteDocker(step *payload.Step) int {
	e.logf("[forge-ci] setup_remote_docker: docker commands in this job use the runner's Docker daemon")
	if !step.LayerCaching {
		return 0
	}
	bc := e.claim.DockerBuildCache
	if bc == nil {
		return e.warnZero("docker_layer_caching: true but this forge-ci server has no " +
			"FORGE_CI_BUILD_CACHE_REGISTRY configured — building without a shared layer cache")
	}
	e.logf("[forge-ci] layer cache: %s — layers are exported during builds and restored on the next runner", bc.Ref)
	return e.prepareBuildCache(bc)
}

// prepareBuildCache does registry login + buildx + the per-job builder + the
// forge-ci-build wrapper, in that order. Every failure warns and gives up on
// the cache for this job (the build itself still runs, uncached).
func (e *Executor) prepareBuildCache(bc *payload.BuildCache) int {
	if bc.Username != nil && *bc.Username != "" {
		res, err := e.runLogged(e.cacheLoginArgs()...)
		if err != nil || res.exitCode != 0 {
			return e.warnZero("layer cache: docker login failed; skipping cache setup")
		}
	}
	if !e.ensureBuildx() {
		return e.warnZero("layer cache: no usable buildx in the job image and no BUILDX_BIN on " +
			"the runner — set docker_layer_caching: false or use an image with buildx")
	}
	res, err := e.runLogged(e.buildxCreateArgs()...)
	if err != nil || res.exitCode != 0 {
		return e.warnZero("layer cache: docker buildx create failed (exit %d)", res.exitCode)
	}
	e.mu.Lock()
	e.buildxCreated = true
	e.mu.Unlock()

	if res, err := e.runLogged(e.cfg.DockerBin, "cp", e.scriptPath(buildWrapperFile), e.container+":"+forgeBuildIn); err != nil || res.exitCode != 0 {
		return e.warnZero("layer cache: could not install %s (exit %d)", forgeBuildIn, res.exitCode)
	}
	if res, err := e.runLogged(e.wrapperChmodArgs()...); err != nil || res.exitCode != 0 {
		return e.warnZero("layer cache: could not make %s executable (exit %d)", forgeBuildIn, res.exitCode)
	}
	e.logf("[forge-ci] layer cache ready: build with `forge-ci-build` (or docker buildx "+
		"build --builder %s --cache-from type=registry,ref=$FORGE_CI_BUILD_CACHE_FROM "+
		"--cache-to type=registry,ref=$FORGE_CI_BUILD_CACHE_TO,mode=max)", e.buildxBuilderName)
	return 0
}

// ensureBuildx returns true when the container can run docker buildx —
// natively, or via the runner's BUILDX_BIN copied into the CLI-plugin path.
func (e *Executor) ensureBuildx() bool {
	res, err := e.runLogged(e.buildxCheckArgs()...)
	if err == nil && res.exitCode == 0 {
		return true
	}
	if e.cfg.BuildxBin == "" {
		return false
	}
	for _, args := range [][]string{e.buildxMkdirArgs(), e.buildxCopyArgs(), e.buildxChmodArgs(), e.buildxCheckArgs()} {
		res, err = e.runLogged(args...)
		if err != nil || res.exitCode != 0 {
			return false
		}
	}
	return true
}

// --- helpers --------------------------------------------------------------------

func nonEmpty(in []string) []string {
	out := make([]string, 0, len(in))
	for _, s := range in {
		if strings.TrimSpace(s) != "" {
			out = append(out, s)
		}
	}
	return out
}

// uploadCtx bounds control-plane transfers independently of the job context:
// they must remain possible during finalization after an interrupt.
func (e *Executor) uploadCtx() context.Context {
	if e.runCtx.Err() == nil {
		return e.runCtx
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	go func() {
		<-ctx.Done()
		cancel()
	}()
	return ctx
}
