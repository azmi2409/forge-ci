package executor

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The embedded bash helpers must stay byte-identical to the canonical
// copies in runner/lib (one canonical copy during the transition; the
// shipped binary embeds exactly these).
func TestEmbeddedHelpersMatchCanonical(t *testing.T) {
	pairs := map[string][2]string{
		"circleci_cli.sh": {
			filepath.Join("..", "..", "..", "runner", "lib", "forge_ci_runner", "circleci_cli.sh"),
			string(circleCLIScript),
		},
		"docker_build_wrapper.sh": {
			filepath.Join("..", "..", "..", "runner", "lib", "forge_ci_runner", "docker_build_wrapper.sh"),
			string(buildWrapperScript),
		},
	}
	for name, pair := range pairs {
		want, err := os.ReadFile(pair[0])
		if err != nil {
			t.Fatalf("read canonical %s: %v", pair[0], err)
		}
		if pair[1] != string(want) {
			t.Errorf("embedded %s diverged from the canonical runner/lib copy — re-copy, never fork", name)
		}
	}
}

// The embedded circleci helper behaves like the Ruby suite expects:
// glob, split (disjoint shares covering all files), and run (skip when the
// share is empty, pipe it when not).
func TestCircleCLIHelperBehavior(t *testing.T) {
	bash := findBash4(t)
	if bash == "" {
		t.Skip("bash >= 4 not available (the helper needs globstar; Linux runners have it)")
	}
	dir := t.TempDir()
	files := []string{"a_test.rb", "b_test.rb", "c_test.rb", "d_test.rb"}
	for i, f := range files {
		os.WriteFile(filepath.Join(dir, f), []byte(strings.Repeat("x", (i+1)*100)), 0o644)
	}

	script := filepath.Join(t.TempDir(), "circleci")
	os.WriteFile(script, circleCLIScript, 0o755)

	run := func(env []string, stdin string, args ...string) (string, int) {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, bash, append([]string{script}, args...)...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), env...)
		if stdin != "" {
			cmd.Stdin = strings.NewReader(stdin)
		}
		out, err := cmd.CombinedOutput()
		code := 0
		if exitErr, ok := err.(*exec.ExitError); ok {
			code = exitErr.ExitCode()
		} else if err != nil {
			t.Fatalf("run %v: %v", args, err)
		}
		return string(out), code
	}

	// glob
	out, code := run(nil, "", "tests", "glob", "*_test.rb")
	if code != 0 {
		t.Fatalf("glob exit %d: %s", code, out)
	}
	for _, f := range files {
		if !strings.Contains(out, f) {
			t.Errorf("glob missing %s: %s", f, out)
		}
	}

	// split by name: 2 nodes -> disjoint shares covering all files
	list := strings.Join(files, "\n") + "\n"
	out0, code := run([]string{"CIRCLE_NODE_TOTAL=2", "CIRCLE_NODE_INDEX=0"}, list, "tests", "split")
	if code != 0 {
		t.Fatalf("split node0 exit %d: %s", code, out0)
	}
	out1, code := run([]string{"CIRCLE_NODE_TOTAL=2", "CIRCLE_NODE_INDEX=1"}, list, "tests", "split")
	if code != 0 {
		t.Fatalf("split node1 exit %d: %s", code, out1)
	}
	both := out0 + out1
	for _, f := range files {
		if n := strings.Count(both, f); n != 1 {
			t.Errorf("file %s appears %d times across nodes (want exactly 1)", f, n)
		}
	}

	// split by filesize falls back sensibly (no timings on forge-ci yet)
	out, code = run([]string{"CIRCLE_NODE_TOTAL=2", "CIRCLE_NODE_INDEX=0"}, list, "tests", "split", "--split-by=timings")
	if code != 0 || !strings.Contains(out, "_test.rb") {
		t.Errorf("filesize split: code=%d out=%q", code, out)
	}

	// run: empty share -> command skipped, exit 0
	_, code = run([]string{"CIRCLE_NODE_TOTAL=1", "CIRCLE_NODE_INDEX=0"}, "", "tests", "run", "--command=cat")
	if code != 0 {
		t.Errorf("tests run with empty share must exit 0, got %d", code)
	}
	// run: non-empty share pipes it to the command
	out, code = run([]string{"CIRCLE_NODE_TOTAL=1", "CIRCLE_NODE_INDEX=0"}, "picked_test.rb\n", "tests", "run", "--command=cat")
	if code != 0 || !strings.Contains(out, "picked_test.rb") {
		t.Errorf("tests run: code=%d out=%q", code, out)
	}
}

// findBash4 returns a bash with major version >= 4 (globstar support), or "".
func findBash4(t *testing.T) string {
	t.Helper()
	for _, candidate := range []string{
		os.Getenv("BASH_TEST_BIN"),
		"/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash", "/usr/bin/bash",
	} {
		if candidate == "" {
			continue
		}
		out, err := exec.Command(candidate, "-c", "echo $BASH_VERSION").Output()
		if err != nil {
			continue
		}
		var major int
		if _, err := fmt.Sscanf(string(out), "%d", &major); err == nil && major >= 4 {
			return candidate
		}
	}
	return ""
}
