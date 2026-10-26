package executor

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// TestDockerIntegration runs a real job in a real container. It skips when
// docker is unavailable locally, but CI MUST provide docker (the plan's
// verification gate: this test is required, not universally skipped).
func TestDockerIntegration(t *testing.T) {
	bin := os.Getenv("DOCKER_BIN")
	if bin == "" {
		bin = "docker"
	}
	if !DockerAvailable(bin) {
		t.Skip("docker not available; CI runs this test with docker present")
	}

	// Use a tiny image; pull happens as part of the job.
	claimJSON := `{
      "id": 9001, "name": "integration",
      "executor": {"image": "busybox:latest"},
      "steps": [
        {"type": "run", "name": "hello", "command": "test \"$PWD\" = / && test -z \"${CIRCLE_WORKING_DIRECTORY+x}\" && echo hello-from-container && echo token=$INTEGRATION_SECRET"},
        {"type": "run", "name": "fail", "command": "false"},
        {"type": "run", "name": "rescue", "command": "echo rescue-ran", "when": "on_fail"}
      ],
      "environment": {"INTEGRATION_SECRET": "integration-secret-value"},
      "pipeline": {"sha": "deadbeef", "branch": "main"}
    }`
	claim, err := payload.ParseClaim([]byte(claimJSON))
	if err != nil {
		t.Fatal(err)
	}
	cfg := testCfg(bin)
	cfg.JobTimeout = 120
	cfg.StepNoOutputTimeout = 60

	cp := &fakeCP{}
	e := New(cfg, cp, claim)
	start := time.Now()
	status, results := e.Execute(context.Background(), func() bool { return false }, func() bool { return false })
	t.Logf("job took %s", time.Since(start))

	if status != StatusFailed {
		t.Fatalf("status %s", status)
	}
	if len(results) != 3 || results[0].ExitCode != 0 || results[1].ExitCode != 1 || results[2].ExitCode != 0 {
		t.Fatalf("results: %+v", results)
	}
	log := cp.log()
	if !strings.Contains(log, "hello-from-container") || !strings.Contains(log, "rescue-ran") {
		t.Fatalf("container output missing: %q", log)
	}
	if strings.Contains(log, "integration-secret-value") || !strings.Contains(log, "[REDACTED]") {
		t.Fatalf("redaction failed in real container: %q", log)
	}

	// No leaked containers or networks after the run (gate: cleanup after
	// failure paths too).
	assertNoLeak(t, bin, "name=forge-ci-job-9001")
	assertNoLeak(t, bin, "name=buildx_buildkit_forge-ci-bx-9001")
	assertNoLeak(t, bin, "name=forge-ci-net-9001")
}

// assertNoLeak fails when a docker object matching the filter still exists.
func assertNoLeak(t *testing.T, dockerBin, filter string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	res, err := runCapture(ctx, []string{dockerBin, "ps", "-a", "--filter", filter, "--format", "{{.Names}}"})
	if err != nil {
		t.Fatalf("leak check %q: %v", filter, err)
	}
	if strings.TrimSpace(res.output) != "" {
		t.Errorf("leaked object matching %q: %s", filter, strings.TrimSpace(res.output))
	}
}

func TestDockerTimeoutRemovesContainerBeforeNextStep(t *testing.T) {
	bin := os.Getenv("DOCKER_BIN")
	if bin == "" {
		bin = "docker"
	}
	if !DockerAvailable(bin) {
		t.Skip("docker not available; CI runs this test with docker present")
	}
	claim, err := payload.ParseClaim([]byte(`{
	  "id":9002,"name":"timeout-processes","executor":{"image":"busybox:latest"},
	  "steps":[
	    {"type":"run","background":true,"command":"sleep 300"},
	    {"type":"run","command":"sleep 300 & wait"}
	  ]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	cfg := testCfg(bin)
	cfg.StepNoOutputTimeout = 0.5
	e := New(cfg, &fakeCP{}, claim)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	e.runCtx = ctx
	defer e.streamer.Close()
	defer e.cleanup()
	if err := e.unpackScripts(); err != nil {
		t.Fatal(err)
	}
	if err := e.setupContainers(); err != nil {
		t.Fatal(err)
	}
	if code := e.executeRun(&claim.Steps[0]); code != 0 {
		t.Fatalf("background launch exit=%d", code)
	}
	if code := e.executeRun(&claim.Steps[1]); code != timeoutExit {
		t.Fatalf("timeout exit=%d", code)
	}
	// Check before deferred job cleanup. Both detached and foreground
	// container processes must already be gone when the step returns.
	assertNoLeak(t, bin, "name="+e.container)
}
