package executor

import (
	"reflect"
	"strings"
	"testing"

	"github.com/azmi2409/forge-ci/runner-go/internal/config"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

func testExecutor(t *testing.T, claimJSON string) *Executor {
	t.Helper()
	claim, err := payload.ParseClaim([]byte(claimJSON))
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		DockerBin:        "docker",
		DockerSocketPath: "/var/run/docker.sock",
		RedactMinLength:  8,
		JobTimeout:       3600,
		LogChunkSize:     65536,
		LogFlushInterval: 1,
	}
	return New(cfg, nil, claim)
}

const fullClaim = `{
  "id": 7, "name": "test", "working_directory": "~/app",
  "executor": {"image": "cimg/ruby:3.2", "entrypoint": "/bin/sh", "command": "sleep 1"},
  "steps": [{"type": "run", "command": "echo hi"}],
  "environment": {"JOBVAR": "job-value-1"},
  "pipeline": {"sha": "abc123", "branch": "feat/x"},
  "trusted": true, "workflow_run_id": 907, "project_id": 12,
  "repository": {"url": "https://x-access-token:tok123@github.com/acme/widgets.git", "sha": "abc123", "token": "ghstoken"},
  "docker_build_cache": {"registry": "reg.example.com/cache", "ref": "reg.example.com/cache:p12-feat-x",
                          "username": "AWS", "password": "ecrpw12345"}
}`

func TestPrimaryRunArgs(t *testing.T) {
	e := testExecutor(t, fullClaim)
	args, err := e.primaryRunArgs()
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"docker", "run", "-d", "--name", "forge-ci-job-7-" + e.suffix, "--network", "forge-ci-net-7-" + e.suffix,
		"-w", "/root/app",
		// job env (spot-check a few)
		"-e", "CI=true", "-e", "CIRCLECI=true", "-e", "FORGE_CI=true", "-e", "BASH_ENV=" + bashEnvPath,
		"-e", "CIRCLE_BRANCH=feat/x", "-e", "CIRCLE_SHA1=abc123", "-e", "CIRCLE_JOB=test",
		"-e", "CIRCLE_BUILD_NUM=7", "-e", "CIRCLE_NODE_INDEX=0", "-e", "CIRCLE_NODE_TOTAL=1",
		"-e", "CIRCLE_WORKFLOW_ID=907", "-e", "CIRCLE_WORKING_DIRECTORY=/root/app",
		"-e", "CIRCLE_REPOSITORY_URL=https://github.com/acme/widgets.git",
		"-e", "CIRCLE_PROJECT_USERNAME=acme", "-e", "CIRCLE_PROJECT_REPONAME=widgets",
		"-e", "JOBVAR=job-value-1",
		"--entrypoint", "/bin/sh", "cimg/ruby:3.2", "/bin/sh", "-c", "sleep 1",
	}
	if len(args) < len(want) {
		t.Fatalf("args too short: %v", args)
	}
	// The layer-cache env is absent: this claim has no setup_remote_docker step.
	for _, a := range args {
		if strings.HasPrefix(a, "FORGE_CI_BUILD_CACHE") {
			t.Fatalf("cache env leaked into a non-layer-caching job: %v", args)
		}
	}
	// Prefix must match; env map order is nondeterministic so compare sets.
	idx := 0
	for _, w := range want {
		if w == "CI=true" {
			break
		}
		if args[idx] != w {
			t.Fatalf("arg %d = %q want %q (full: %v)", idx, args[idx], w, args)
		}
		idx++
	}
	envSet := map[string]bool{}
	for i := 0; i < len(args)-1; i++ {
		if args[i] == "-e" {
			envSet[args[i+1]] = true
		}
	}
	for _, w := range want {
		if strings.HasPrefix(w, "-e") {
			continue
		}
		if strings.Contains(w, "=") && !envSet[w] && w != "JOBVAR=job-value-1" && !strings.HasPrefix(w, "CIRCLE") && !strings.HasPrefix(w, "BASH_ENV") && !strings.HasPrefix(w, "FORGE") {
			t.Errorf("missing env %q in %v", w, args)
		}
	}
	if !envSet["JOBVAR=job-value-1"] {
		t.Errorf("job env missing: %v", args)
	}
}

func TestPrimaryRunArgsMissingImage(t *testing.T) {
	e := testExecutor(t, `{"id": 1, "name": "x", "steps": []}`)
	if _, err := e.primaryRunArgs(); err == nil {
		t.Fatal("missing executor.image must error")
	}
}

func TestJobEnvironmentPrecedence(t *testing.T) {
	e := testExecutor(t, fullClaim)
	env := e.jobEnvironment()
	// A job var clashing with a builtin wins.
	e.claim.Environment["CI"] = "custom"
	env = e.jobEnvironment()
	if env["CI"] != "custom" {
		t.Fatalf("job env must win: %v", env["CI"])
	}
}

func TestServiceRunArgs(t *testing.T) {
	e := testExecutor(t, fullClaim)
	name, args := e.serviceRunArgs(payload.ServiceImage{
		Image:       "postgres:16",
		Name:        strPtr("db"),
		Environment: payload.Env{"POSTGRES_PASSWORD": "ci-secret"},
		Command:     strPtr("postgres"),
	}, 0)
	if name != "db" {
		t.Fatalf("name %q", name)
	}
	want := []string{"docker", "run", "-d", "--name", "db", "--network", "forge-ci-net-7-" + e.suffix,
		"--network-alias", "db", "-e", "POSTGRES_PASSWORD=ci-secret", "--entrypoint" /*absent*/}
	_ = want
	joined := strings.Join(args, " ")
	for _, frag := range []string{"--name db", "--network-alias db", "-e POSTGRES_PASSWORD=ci-secret", "postgres:16", "/bin/sh -c postgres"} {
		if !strings.Contains(joined, frag) {
			t.Errorf("missing %q in %s", frag, joined)
		}
	}
	// Unnamed services get a deterministic fallback name.
	name2, _ := e.serviceRunArgs(payload.ServiceImage{Image: "redis:7"}, 1)
	if name2 != "forge-ci-svc-1-"+e.suffix {
		t.Fatalf("fallback name %q", name2)
	}
}

func TestExecArgs(t *testing.T) {
	e := testExecutor(t, fullClaim)
	e.defaultShell = bashShell
	step := &payload.Step{
		Command:     strPtr("echo hi"),
		Environment: payload.Env{"STEPVAR": "step-value-9"},
	}
	args := e.execArgs(step, false)
	joined := strings.Join(args, " ")
	for _, frag := range []string{
		"docker exec", "-w /root/app", "forge-ci-job-7-" + e.suffix,
		"/bin/bash -eo pipefail -c echo hi", "-e STEPVAR=step-value-9",
	} {
		if !strings.Contains(joined, frag) {
			t.Errorf("missing %q in %s", frag, joined)
		}
	}
	// Detached adds -d.
	args = e.execArgs(step, true)
	if !strings.Contains(strings.Join(args, " "), "docker exec -d ") {
		t.Errorf("detached flag missing: %v", args)
	}
	// Explicit posix shell override.
	step.Shell = strPtr("/bin/sh")
	args = e.execArgs(step, false)
	if !strings.Contains(strings.Join(args, " "), "/bin/sh -c echo hi") {
		t.Errorf("shell override: %v", args)
	}
}

func TestCheckoutScript(t *testing.T) {
	script, env := checkoutScript("/root/project", "/root/project", "https://github.com/acme/w.git", "abc123", "")
	if env != nil {
		t.Fatalf("no token -> no env: %v", env)
	}
	for _, frag := range []string{
		"git init /root/project",
		"remote add origin https://github.com/acme/w.git",
		"fetch --depth 1 origin abc123",
		"checkout abc123",
	} {
		if !strings.Contains(script, frag) {
			t.Errorf("missing %q in %s", frag, script)
		}
	}
	if !strings.Contains(script, " && ") {
		t.Error("commands must be &&-chained")
	}

	script, env = checkoutScript("/root/project", "/root/project", "https://github.com/acme/w.git", "abc123", "tok-xyz")
	if len(env) != 2 || env[0] != "-e" || !strings.HasPrefix(env[1], "FORGE_CI_CHECKOUT_TOKEN=tok-xyz") {
		t.Fatalf("token env: %v", env)
	}
	for _, frag := range []string{
		"http.extraHeader=",
		"Authorization: Basic",
		"x-access-token:%s",
		"FORGE_CI_CHECKOUT_TOKEN",
	} {
		if !strings.Contains(script, frag) {
			t.Errorf("missing %q in %s", frag, script)
		}
	}
	// Token must not be embedded in the script itself.
	if strings.Contains(script, "tok-xyz") {
		t.Error("token leaked into the checkout script")
	}
}

func TestBuildCacheEnvironment(t *testing.T) {
	// The full claim has no setup_remote_docker step -> no cache env.
	e := testExecutor(t, fullClaim)
	if env := e.buildCacheEnvironment(); env != nil {
		t.Fatalf("cache env without layer_caching: %v", env)
	}

	// With a layer-caching step the refs and creds appear.
	e = testExecutor(t, `{
      "id": 8, "name": "b", "workflow_run_id": 5,
      "executor": {"image": "alpine"},
      "steps": [{"type": "setup_remote_docker", "layer_caching": true}],
      "pipeline": {"branch": "main"},
      "docker_build_cache": {"registry": "reg.example.com/cache", "ref": "reg.example.com/cache:p12-main",
                               "username": "AWS", "password": "ecrpw12345"}
    }`)
	env := e.buildCacheEnvironment()
	want := map[string]string{
		"FORGE_CI_BUILD_CACHE_REGISTRY": "reg.example.com/cache",
		"FORGE_CI_BUILD_CACHE_FROM":     "reg.example.com/cache:p12-main",
		"FORGE_CI_BUILD_CACHE_TO":       "reg.example.com/cache:p12-main",
		"FORGE_CI_BUILD_CACHE_IMAGE":    "cache:p12-main",
		"FORGE_CI_BUILD_BUILDER":        e.buildxBuilderName,
		"FORGE_CI_BUILD_CACHE_USERNAME": "AWS",
		"FORGE_CI_BUILD_CACHE_PASSWORD": "ecrpw12345",
	}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("%s = %q want %q", k, env[k], v)
		}
	}

	// Unauthenticated registry: no username/password keys.
	e = testExecutor(t, `{
      "id": 9, "name": "c",
      "executor": {"image": "alpine"},
      "steps": [{"type": "setup_remote_docker", "layer_caching": true}],
      "pipeline": {"branch": "main"},
      "docker_build_cache": {"registry": "reg.example.com/cache", "ref": "reg.example.com/cache:p12-main"}
    }`)
	env = e.buildCacheEnvironment()
	if _, ok := env["FORGE_CI_BUILD_CACHE_USERNAME"]; ok {
		t.Error("username must be absent for unauthenticated registry")
	}
}

func TestDockerSocketArgs(t *testing.T) {
	e := testExecutor(t, fullClaim)
	if args := e.dockerSocketArgs(); args != nil {
		t.Fatalf("no setup_remote_docker step -> no socket args: %v", args)
	}
	e = testExecutor(t, `{"id": 2, "name": "d",
      "executor": {"image": "alpine"},
      "steps": [{"type": "setup_remote_docker"}],
      "pipeline": {}}`)
	args := e.dockerSocketArgs()
	if len(args) < 2 || args[0] != "-v" || !strings.HasPrefix(args[1], "/var/run/docker.sock:") {
		t.Fatalf("socket args: %v", args)
	}
}

func TestWorkspaceKeys(t *testing.T) {
	cases := map[string]string{
		".":           "forge-ci-workspace/907/root.tgz",
		"./public":    "forge-ci-workspace/907/public.tgz",
		"tmp/cache":   "forge-ci-workspace/907/tmp-cache.tgz",
		"":            "forge-ci-workspace/907/root.tgz",
		"app/assets/": "forge-ci-workspace/907/app-assets.tgz",
	}
	for root, want := range cases {
		if got := workspaceRootKey(907, root); got != want {
			t.Errorf("workspaceRootKey(%q) = %q want %q", root, got, want)
		}
	}
	e := testExecutor(t, fullClaim)
	if got := e.workspaceManifestKey(); got != "forge-ci-workspace/907/manifest.json" {
		t.Errorf("manifest key %q", got)
	}
}

func TestParseDuration(t *testing.T) {
	cases := map[string]float64{
		"30s": 30, "10m": 600, "1h": 3600, "45": 45, "2.5m": 150,
		"": 0, "abc": 0, "10x": 0, "-5s": 0,
	}
	for in, want := range cases {
		if got := parseDuration(in); got != want {
			t.Errorf("parseDuration(%q) = %v want %v", in, got, want)
		}
	}
}

func TestShellWords(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"/bin/bash -eo pipefail", []string{"/bin/bash", "-eo", "pipefail"}},
		{`sh -c "echo 'a b'"`, []string{"sh", "-c", "echo 'a b'"}},
		{`a\ b`, []string{"a b"}},
		{"  spaced   out  ", []string{"spaced", "out"}},
		{"", nil},
		{`'single quo''ted'`, []string{"single quoted"}},
	}
	for _, tc := range cases {
		got := shellWords(tc.in)
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("shellWords(%q) = %v want %v", tc.in, got, tc.want)
		}
	}
}

func TestShellQuote(t *testing.T) {
	if got := shellQuote("plain"); got != "plain" {
		t.Errorf("plain: %q", got)
	}
	if got := shellQuote("has space"); got != "'has space'" {
		t.Errorf("space: %q", got)
	}
	if got := shellQuote("it's"); got != `'it'\''s'` {
		t.Errorf("quote: %q", got)
	}
	if got := shellQuote(""); got != "''" {
		t.Errorf("empty: %q", got)
	}
}

func TestStripUserinfo(t *testing.T) {
	cases := map[string]string{
		"https://user:tok@github.com/a/b.git": "https://github.com/a/b.git",
		"https://x-access-token:abc@host/x":   "https://host/x",
		"https://github.com/a/b.git":          "https://github.com/a/b.git",
	}
	for in, want := range cases {
		if got := stripUserinfo(in); got != want {
			t.Errorf("stripUserinfo(%q) = %q want %q", in, got, want)
		}
	}
}

func TestRemoteDockerAndLayerCaching(t *testing.T) {
	e := testExecutor(t, fullClaim)
	if e.remoteDocker() || e.layerCaching() {
		t.Fatal("plain job must not request remote docker")
	}
	e = testExecutor(t, `{"id": 3, "name": "x",
      "executor": {"image": "alpine"},
      "steps": [{"type": "run", "command": "x"}, {"type": "setup_remote_docker", "layer_caching": true}],
      "pipeline": {}}`)
	if !e.remoteDocker() || !e.layerCaching() {
		t.Fatal("layer-caching job must set both flags")
	}
}

func strPtr(s string) *string { return &s }
