package executor

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunStreamExitCodes(t *testing.T) {
	res, err := runStream(context.Background(), []string{"sh", "-c", "exit 0"}, func([]byte) {})
	if err != nil || res.exitCode != 0 {
		t.Fatalf("exit 0: %v %v", res, err)
	}
	res, err = runStream(context.Background(), []string{"sh", "-c", "exit 3"}, func([]byte) {})
	if err != nil || res.exitCode != 3 {
		t.Fatalf("exit 3: %v %v", res, err)
	}
	res, err = runStream(context.Background(), []string{"sh", "-c", "echo out; echo err >&2"}, func([]byte) {})
	if err != nil || res.exitCode != 0 || !strings.Contains(res.output, "") {
		t.Fatalf("echo: %v %v", res, err)
	}
	// Missing binary.
	if _, err := runStream(context.Background(), []string{"definitely-not-a-binary-xyz"}, func([]byte) {}); err == nil {
		t.Fatal("missing binary must error")
	}
}

func TestRunStreamContextCancellationKillsGroup(t *testing.T) {
	// The shell spawns a grandchild; the group kill must take both down and
	// return promptly.
	ctx, cancel := context.WithCancel(context.Background())
	start := time.Now()
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	_, err := runStream(ctx, []string{"sh", "-c", "sleep 30 & wait"}, func([]byte) {})
	if err == nil {
		t.Fatal("cancellation must be reported")
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("cancellation took too long: %v", elapsed)
	}
}

func TestRunCapture(t *testing.T) {
	res, err := runCapture(context.Background(), []string{"sh", "-c", "echo hello-capture"})
	if err != nil || res.exitCode != 0 || !strings.Contains(res.output, "hello-capture") {
		t.Fatalf("capture: %v %v %q", res, err, res.output)
	}
}

func TestStreamedOutputBoundedChunks(t *testing.T) {
	// Output must reach the callback in bounded chunks (never one giant
	// buffer for a long stream), and newline-free output must flow.
	var sizes []int
	var total int
	res, err := runStream(context.Background(), []string{"sh", "-c", "head -c 100000 /dev/zero | tr '\\0' 'x'"}, func(p []byte) {
		sizes = append(sizes, len(p))
		total += len(p)
	})
	if err != nil || res.exitCode != 0 {
		t.Fatalf("run: %v %v", res, err)
	}
	if total != 100000 {
		t.Fatalf("total %d", total)
	}
	for _, s := range sizes {
		if s > 128*1024 {
			t.Fatalf("chunk too large: %d", s)
		}
	}
}

func TestDockerAvailable(t *testing.T) {
	// A fake docker that succeeds.
	dir := t.TempDir()
	fake := filepath.Join(dir, "docker")
	os.WriteFile(fake, []byte("#!/bin/sh\nexit 0\n"), 0o755)
	if !DockerAvailable(fake) {
		t.Fatal("fake docker should be available")
	}
	// One that fails.
	os.WriteFile(fake, []byte("#!/bin/sh\nexit 1\n"), 0o755)
	if DockerAvailable(fake) {
		t.Fatal("failing docker should be unavailable")
	}
	// One that doesn't exist.
	if DockerAvailable(filepath.Join(dir, "missing")) {
		t.Fatal("missing docker should be unavailable")
	}
}
