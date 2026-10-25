package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Subprocess rules (per the frozen plan):
//
//   - Every subprocess starts in its own process group (Setpgid); stopping
//     it means TERM to the whole group, a bounded grace, then KILL to the
//     group — a killed `docker exec` client does NOT stop container-side
//     processes, so job-level interruption paths also stop/remove the
//     containers themselves (cleanupContainers).
//   - cmd.WaitDelay bounds the internal output-copier when a grandchild
//     holds the pipe; it is belt-and-braces next to the group kill.
//   - Every docker operation — pull, network, run, exec, cp, buildx — runs
//     under the job context (job deadline + interrupt), never unbounded.
//     Cleanup runs under its OWN bounded context so shutdown cannot hang.

const (
	killGrace     = 5 * time.Second
	watchdogTick  = 500 * time.Millisecond
	cleanupBudget = 60 * time.Second
	dockerInfoTO  = 10 * time.Second
)

// processGroup attr for all spawned commands.
func procAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true}
}

// terminateGroup TERM -> bounded grace -> KILL the whole process group.
func terminateGroup(pid int) {
	if pid <= 0 {
		return
	}
	pgid := -pid // negative pid targets the group
	if err := syscall.Kill(pgid, syscall.SIGTERM); err != nil {
		// Already gone.
		return
	}
	deadline := time.Now().Add(killGrace)
	for time.Now().Before(deadline) {
		// Signal 0 checks existence of the group.
		if err := syscall.Kill(pgid, 0); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	syscall.Kill(pgid, syscall.SIGKILL)
}

// runResult carries what a docker invocation produced.
type runResult struct {
	output   string // combined stdout+stderr (when captured)
	exitCode int
}

var errInterrupted = errors.New("interrupted")

// startStreamed launches argv with its own process group, streaming
// combined output to onOutput in bounded chunks (exec's internal copier
// reads ≤32KB at a time). The returned channel carries cmd.Wait's result.
func startStreamed(argv []string, onOutput func([]byte)) (*exec.Cmd, <-chan error, error) {
	if len(argv) == 0 {
		return nil, nil, errors.New("empty argv")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.SysProcAttr = procAttr()
	cmd.WaitDelay = killGrace
	w := &outputFunc{fn: onOutput}
	cmd.Stdout = w
	cmd.Stderr = w

	if err := cmd.Start(); err != nil {
		return nil, nil, fmt.Errorf("%s: %w", argv[0], err)
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()
	return cmd, waitCh, nil
}

// runStream runs argv to completion, killing the process group when ctx is
// done. Returns the exit code (or -1 with errInterrupted).
func runStream(ctx context.Context, argv []string, onOutput func([]byte)) (runResult, error) {
	cmd, waitCh, err := startStreamed(argv, onOutput)
	if err != nil {
		return runResult{exitCode: -1}, err
	}
	select {
	case werr := <-waitCh:
		return runResult{exitCode: exitOf(werr, cmd)}, nil
	case <-ctx.Done():
		terminateGroup(cmd.Process.Pid)
		// Reap: Wait returns once the process died; WaitDelay bounds the
		// copier if a grandchild holds the pipe.
		<-waitCh
		return runResult{exitCode: -1}, errInterrupted
	}
}

// runCapture runs argv collecting combined output without streaming it to
// the job log (small queries like sha256sum).
func runCapture(ctx context.Context, argv []string) (runResult, error) {
	var buf bytes.Buffer
	res, err := runStream(ctx, argv, func(p []byte) { buf.Write(p) })
	res.output = buf.String()
	return res, err
}

// exitOf maps a Wait error to an exit code: 0 on success, the process exit
// code on failure, 137 for signal kills.
func exitOf(err error, cmd *exec.Cmd) int {
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		if status, ok := exitErr.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal())
		}
		return exitErr.ExitCode()
	}
	return -1
}

// outputFunc adapts a callback to io.Writer for exec's internal copier.
type outputFunc struct {
	fn func([]byte)
	mu sync.Mutex
}

func (w *outputFunc) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.fn(p)
	return len(p), nil
}

// DockerAvailable reports whether the docker CLI works (`docker info`).
func DockerAvailable(dockerBin string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), dockerInfoTO)
	defer cancel()
	res, err := runCapture(ctx, []string{dockerBin, "info"})
	return err == nil && res.exitCode == 0
}
