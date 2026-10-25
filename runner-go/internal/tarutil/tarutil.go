// Package tarutil wraps the system tar for host-side tarball work (artifact
// packing, workspace staging) — argv arrays, never a shell, matching the
// Ruby runner. Container-side tarring goes through docker exec in the
// executor.
package tarutil

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// Create builds a .tgz at dest containing paths relative to baseDir.
// Missing paths are skipped with a warning; an error is returned when
// nothing exists to archive.
func Create(ctx context.Context, paths []string, baseDir, dest string, warn func(string)) error {
	var existing []string
	for _, p := range paths {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(baseDir, p)); err != nil {
			warn(fmt.Sprintf("tar: %q does not exist under %s; skipping", p, baseDir))
			continue
		}
		existing = append(existing, p)
	}
	if len(existing) == 0 {
		return fmt.Errorf("nothing to archive")
	}
	return run(ctx, nil, "tar", append([]string{"-czf", dest, "-C", baseDir}, existing...)...)
}

// Extract unpacks a .tgz into destDir (created if missing).
func Extract(ctx context.Context, tgz, destDir string) error {
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	return run(ctx, nil, "tar", "-xzf", tgz, "-C", destDir)
}

func run(ctx context.Context, out *strings.Builder, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if out != nil {
		cmd.Stdout = out
		cmd.Stderr = out
	} else {
		cmd.Stdout = io.Discard
		cmd.Stderr = io.Discard
	}
	return cmd.Run()
}
