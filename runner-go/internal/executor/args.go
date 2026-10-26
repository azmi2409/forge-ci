package executor

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// Pure argv and script builders, unit-tested directly (ported from the
// Ruby executor's builders). Nothing here touches processes or the network.

const (
	bashShell    = "/bin/bash -eo pipefail"
	posixShell   = "/bin/sh"
	bashEnvPath  = "/tmp/forge-ci-bash-env"
	circlecliIn  = "/usr/local/bin/circleci"
	forgeBuildIn = "/usr/local/bin/forge-ci-build"
	buildxPlugin = "/usr/local/lib/docker/cli-plugins/docker-buildx"
	// Workspaces live on the cache API under this reserved namespace.
	workspacePrefix = "forge-ci-workspace"
)

var repoURLRe = regexp.MustCompile(`github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?\z`)

// envArgs renders -e K=V pairs.
func envArgs(env payload.Env) []string {
	args := make([]string, 0, len(env)*2)
	for k, v := range env {
		args = append(args, "-e", k+"="+v)
	}
	return args
}

// builtinEnvironment is the CircleCI-compatible set. Kept separate from the
// job environment so the redactor doesn't mask branch names and SHAs; the
// job's own environment wins on a clash.
func (e *Executor) builtinEnvironment() payload.Env {
	env := payload.Env{
		"CI":                "true",
		"CIRCLECI":          "true",
		"FORGE_CI":          "true",
		"BASH_ENV":          bashEnvPath,
		"CIRCLE_JOB":        e.claim.Name,
		"CIRCLE_BUILD_NUM":  strconv.FormatInt(e.claim.ID, 10),
		"CIRCLE_NODE_INDEX": strconv.Itoa(e.claim.Node()),
		"CIRCLE_NODE_TOTAL": strconv.Itoa(e.claim.Parallel()),
	}
	if e.claim.Pipeline.Branch != nil && *e.claim.Pipeline.Branch != "" {
		env["CIRCLE_BRANCH"] = *e.claim.Pipeline.Branch
	}
	if e.claim.Pipeline.SHA != "" {
		env["CIRCLE_SHA1"] = e.claim.Pipeline.SHA
	}
	if e.workflowID != nil {
		env["CIRCLE_WORKFLOW_ID"] = strconv.FormatInt(*e.workflowID, 10)
	}
	if wd := payload.ExpandWorkdir(e.claim.WorkingDirectory); wd != "" {
		env["CIRCLE_WORKING_DIRECTORY"] = wd
	}
	if e.claim.Repository != nil && e.claim.Repository.URL != "" {
		repoURL := stripUserinfo(e.claim.Repository.URL)
		env["CIRCLE_REPOSITORY_URL"] = repoURL
		if m := repoURLRe.FindStringSubmatch(repoURL); m != nil {
			env["CIRCLE_PROJECT_USERNAME"] = m[1]
			env["CIRCLE_PROJECT_REPONAME"] = m[2]
		}
	}
	return env
}

// jobEnvironment is what every step (and forge-ci-build) sees: built-ins,
// then layer-cache vars, then the job's own environment (wins on clash).
func (e *Executor) jobEnvironment() payload.Env {
	env := e.builtinEnvironment().Merge(e.buildCacheEnvironment())
	return env.Merge(e.claim.Environment)
}

// workdir is the effective job working directory.
func (e *Executor) workdir() string {
	if wd := payload.ExpandWorkdir(e.claim.WorkingDirectory); wd != "" {
		return wd
	}
	return "/root/project"
}

// primaryRunArgs starts the long-lived primary container (steps run via
// docker exec inside it).
func (e *Executor) primaryRunArgs() ([]string, error) {
	if e.claim.Executor == nil || e.claim.Executor.Image == "" {
		return nil, fmt.Errorf("job payload is missing executor.image")
	}
	ex := e.claim.Executor
	args := []string{e.cfg.DockerBin, "run", "-d", "--name", e.container, "--network", e.network}
	if wd := payload.ExpandWorkdir(e.claim.WorkingDirectory); wd != "" {
		args = append(args, "-w", wd)
	}
	args = append(args, e.dockerSocketArgs()...)
	args = append(args, envArgs(e.jobEnvironment())...)
	if ex.Entrypoint != nil && *ex.Entrypoint != "" {
		args = append(args, "--entrypoint", *ex.Entrypoint)
	}
	args = append(args, ex.Image)
	if ex.Command != nil && *ex.Command != "" {
		args = append(args, "/bin/sh", "-c", *ex.Command)
	} else {
		args = append(args, "sleep", "infinity")
	}
	return args, nil
}

// dockerSocketArgs mounts the host socket for setup_remote_docker jobs,
// plus its group so a non-root image user can use it.
func (e *Executor) dockerSocketArgs() []string {
	if !e.remoteDocker() {
		return nil
	}
	args := []string{"-v", e.cfg.DockerSocketPath + ":/var/run/docker.sock"}
	if gid, ok := socketGID(e.cfg.DockerSocketPath); ok {
		args = append(args, "--group-add", strconv.Itoa(gid))
	}
	return args
}

// remoteDocker reports whether any step asked for the host's Docker.
func (e *Executor) remoteDocker() bool {
	for _, s := range e.claim.Steps {
		if s.Type == "setup_remote_docker" {
			return true
		}
	}
	return false
}

// layerCaching reports whether any setup_remote_docker step asked for the
// shared layer cache (CircleCI's docker_layer_caching: true).
func (e *Executor) layerCaching() bool {
	for _, s := range e.claim.Steps {
		if s.Type == "setup_remote_docker" && s.LayerCaching {
			return true
		}
	}
	return false
}

// buildCacheEnvironment is the layer-cache env every step (and
// forge-ci-build) sees: cache refs plus the registry login. FROM/TO are the
// same ref — a build reads the branch's cache and overwrites it.
func (e *Executor) buildCacheEnvironment() payload.Env {
	bc := e.claim.DockerBuildCache
	if !e.layerCaching() || bc == nil {
		return nil
	}
	env := payload.Env{
		"FORGE_CI_BUILD_CACHE_REGISTRY": bc.Registry,
		"FORGE_CI_BUILD_CACHE_FROM":     bc.Ref,
		"FORGE_CI_BUILD_CACHE_TO":       bc.Ref,
		// The ref without its registry host, for tools that put their own
		// registry in front (Kamal's builder: cache: image:).
		"FORGE_CI_BUILD_CACHE_IMAGE": refWithoutHost(bc.Ref),
		"FORGE_CI_BUILD_BUILDER":     e.buildxBuilderName,
	}
	if bc.Username != nil {
		env["FORGE_CI_BUILD_CACHE_USERNAME"] = *bc.Username
	}
	if bc.Password != nil {
		env["FORGE_CI_BUILD_CACHE_PASSWORD"] = *bc.Password
	}
	return env
}

func refWithoutHost(ref string) string {
	if i := strings.Index(ref, "/"); i >= 0 {
		return ref[i+1:]
	}
	return ref
}

// serviceRunArgs returns (name, argv) for a service container.
func (e *Executor) serviceRunArgs(svc payload.ServiceImage, index int) (string, []string) {
	name := fmt.Sprintf("forge-ci-svc-%d-%s", index, e.suffix)
	if svc.Name != nil && *svc.Name != "" {
		name = *svc.Name
	}
	args := []string{e.cfg.DockerBin, "run", "-d", "--name", name, "--network", e.network, "--network-alias", name}
	args = append(args, envArgs(svc.Environment)...)
	if svc.Entrypoint != nil && *svc.Entrypoint != "" {
		args = append(args, "--entrypoint", *svc.Entrypoint)
	}
	args = append(args, svc.Image)
	if svc.Command != nil && *svc.Command != "" {
		args = append(args, "/bin/sh", "-c", *svc.Command)
	}
	return name, args
}

// execArgs runs a step's shell command via docker exec.
func (e *Executor) execArgs(step *payload.Step, detached bool) []string {
	shell := step.Shell
	if shell == nil || *shell == "" {
		shell = &e.defaultShell
	}
	args := []string{e.cfg.DockerBin, "exec"}
	if detached {
		args = append(args, "-d")
	}
	if wd := payload.ExpandWorkdir(e.claim.WorkingDirectory); wd != "" {
		args = append(args, "-w", wd)
	}
	args = append(args, envArgs(e.jobEnvironment())...)
	args = append(args, envArgs(step.Environment)...)
	args = append(args, e.container)
	args = append(args, shellWords(*shell)...)
	args = append(args, "-c", derefString(step.Command))
	return args
}

// checkoutScript builds the git clone command list joined with && — sent as
// one /bin/sh -c argv element. The checkout token travels as an env var on
// THIS exec only and an http.extraHeader for the fetch, so it never lands
// in .git/config or any step's environment.
func checkoutScript(workdir, target, repo, sha, token string) (script string, tokenEnv []string) {
	q := shellQuote
	cmds := []string{
		"git init " + q(target),
		"git -C " + q(target) + " remote add origin " + q(repo) + " 2>/dev/null || git -C " + q(target) + " remote set-url origin " + q(repo),
	}
	fetch := "git -C " + q(target) + " fetch --depth 1 origin " + q(sha)
	if token != "" {
		tokenEnv = []string{"-e", "FORGE_CI_CHECKOUT_TOKEN=" + token}
		fetch = "git -C " + q(target) + " -c http.extraHeader=\"Authorization: Basic " +
			"$(printf 'x-access-token:%s' \"$FORGE_CI_CHECKOUT_TOKEN\" | base64 | tr -d '\\n')\" " +
			"fetch --depth 1 origin " + q(sha)
	}
	cmds = append(cmds, fetch, "git -C "+q(target)+" checkout "+q(sha))
	return strings.Join(cmds, " && "), tokenEnv
}

// cacheLoginArgs runs docker login INSIDE the job container (login is
// client-side state; a host-side login would never reach the container's
// docker CLI). The password travels via the environment, never in argv.
func (e *Executor) cacheLoginArgs() []string {
	args := []string{e.cfg.DockerBin, "exec"}
	args = append(args, envArgs(e.buildCacheEnvironment())...)
	args = append(args, e.container, "/bin/sh", "-c",
		`printf %s "$FORGE_CI_BUILD_CACHE_PASSWORD" | docker login --password-stdin -u "$FORGE_CI_BUILD_CACHE_USERNAME" "$FORGE_CI_BUILD_CACHE_REGISTRY"`)
	return args
}

func (e *Executor) buildxCheckArgs() []string {
	return []string{e.cfg.DockerBin, "exec", e.container, "docker", "buildx", "version"}
}

func (e *Executor) buildxMkdirArgs() []string {
	return []string{e.cfg.DockerBin, "exec", "-u", "root", e.container, "mkdir", "-p", dirOf(buildxPlugin)}
}

func (e *Executor) buildxCopyArgs() []string {
	return []string{e.cfg.DockerBin, "cp", e.cfg.BuildxBin, e.container + ":" + buildxPlugin}
}

func (e *Executor) buildxChmodArgs() []string {
	return []string{e.cfg.DockerBin, "exec", "-u", "root", e.container, "chmod", "+x", buildxPlugin}
}

// buildxCreateArgs makes the per-job docker-container builder. It is NOT
// --use: a builder without --load keeps images out of the daemon, which
// would break plain `docker build -t x . && docker push x`. Steps opt in
// per build via forge-ci-build / --builder "$FORGE_CI_BUILD_BUILDER".
func (e *Executor) buildxCreateArgs() []string {
	return []string{e.cfg.DockerBin, "exec", e.container, "docker", "buildx", "create", "--name", e.buildxBuilderName, "--driver", "docker-container"}
}

func (e *Executor) wrapperCopyArgs() []string {
	return []string{e.cfg.DockerBin, "cp", e.scriptPath(buildWrapperFile), e.container + ":" + forgeBuildIn}
}

func (e *Executor) wrapperChmodArgs() []string {
	return []string{e.cfg.DockerBin, "exec", "-u", "root", e.container, "chmod", "+x", forgeBuildIn}
}

// buildxBuilderContainer is the BuildKit container buildx names after the
// builder; removed with the job in cleanup.
func (e *Executor) buildxBuilderContainer() string {
	return "buildx_buildkit_" + e.buildxBuilderName + "0"
}

// tarCreateArgs tars paths (relative to the workdir) inside the container.
func (e *Executor) tarCreateArgs(tgz string, paths []string, baseDir string) []string {
	return append([]string{e.cfg.DockerBin, "exec", e.container, "tar", "-czf", tgz, "-C", baseDir}, paths...)
}

func (e *Executor) tarExtractArgs(tgz, destDir string) []string {
	return []string{e.cfg.DockerBin, "exec", e.container, "tar", "-xzf", tgz, "-C", destDir}
}

// workspaceKey / manifestKey / rootKey implement the reserved namespace
// (CONTRACT.md "Workspaces").
func (e *Executor) workspaceManifestKey() string {
	return fmt.Sprintf("%s/%d/manifest.json", workspacePrefix, derefInt64(e.workflowID))
}

func workspaceRootKey(workflowID int64, root string) string {
	safe := root
	safe = strings.TrimPrefix(safe, "./")
	safe = nonAlnum.ReplaceAllString(safe, "-")
	safe = strings.Trim(safe, "-")
	if safe == "" {
		safe = "root"
	}
	return fmt.Sprintf("%s/%d/%s.tgz", workspacePrefix, workflowID, safe)
}

var nonAlnum = regexp.MustCompile(`[^A-Za-z0-9]+`)

// parseDuration accepts "30s" / "10m" / "1h" / bare seconds; 0 when
// unparseable (the caller then uses its default).
func parseDuration(v string) float64 {
	m := durRe.FindStringSubmatch(strings.TrimSpace(v))
	if m == nil {
		return 0
	}
	n, _ := strconv.ParseFloat(m[1], 64)
	switch m[2] {
	case "m":
		n *= 60
	case "h":
		n *= 3600
	}
	return n
}

var durRe = regexp.MustCompile(`\A(\d+(?:\.\d+)?)([smh]?)\z`)

// stripUserinfo removes credentials from a URL for logging.
func stripUserinfo(u string) string {
	return userInfoRe.ReplaceAllString(u, "${1}")
}

var userInfoRe = regexp.MustCompile(`(?i)\A([a-z][a-z0-9+.-]*://)[^/@]*@`)

// shellWords splits a shell string like Shellwords (simple POSIX word
// splitting with single/double quotes and backslash escapes).
func shellWords(s string) []string {
	var words []string
	var cur strings.Builder
	inWord := false
	i := 0
	for i < len(s) {
		ch := s[i]
		switch {
		case ch == ' ' || ch == '\t' || ch == '\n':
			if inWord {
				words = append(words, cur.String())
				cur.Reset()
				inWord = false
			}
			i++
		case ch == '\'':
			inWord = true
			j := strings.IndexByte(s[i+1:], '\'')
			if j < 0 {
				cur.WriteString(s[i+1:])
				i = len(s)
				break
			}
			cur.WriteString(s[i+1 : i+1+j])
			i += j + 2
		case ch == '"':
			inWord = true
			i++
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i+1 < len(s) && (s[i+1] == '"' || s[i+1] == '\\') {
					i++
				}
				cur.WriteByte(s[i])
				i++
			}
			i++
		case ch == '\\' && i+1 < len(s):
			inWord = true
			cur.WriteByte(s[i+1])
			i += 2
		default:
			inWord = true
			cur.WriteByte(ch)
			i++
		}
	}
	if inWord || cur.Len() > 0 {
		words = append(words, cur.String())
	}
	return words
}

// shellQuote POSIX-quotes a string for embedding in a shell command.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	for _, ch := range s {
		if strings.ContainsRune("|&;<>()$`\\\"' \t\n*?[#~=%", ch) {
			return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
		}
	}
	return s
}

func derefString(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefInt64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

func dirOf(path string) string {
	if i := strings.LastIndexByte(path, '/'); i > 0 {
		return path[:i]
	}
	return "/"
}
