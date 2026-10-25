package executor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/azmi2409/forge-ci/runner-go/internal/api"
	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// cacheFlowCP serves real files for cache/artifact/workspace flows.
type cacheFlowCP struct {
	t         *testing.T
	mu        sync.Mutex
	store     map[string][]byte // cache key -> tarball bytes
	manifest  []string
	artifacts map[string]string // path -> content
}

func newCacheFlowCP(t *testing.T) *cacheFlowCP {
	return &cacheFlowCP{t: t, store: map[string][]byte{}, artifacts: map[string]string{}}
}

func (f *cacheFlowCP) PutCache(ctx context.Context, projectID int64, key, tarballPath string) (*api.CacheHit, error) {
	b, err := os.ReadFile(tarballPath)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if strings.HasSuffix(key, "manifest.json") {
		json.Unmarshal(b, &f.manifest)
	} else {
		f.store[key] = b
	}
	return &api.CacheHit{Key: key, Size: int64(len(b))}, nil
}

func (f *cacheFlowCP) GetCache(ctx context.Context, projectID int64, keys []string) (*api.CacheHit, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, k := range keys {
		if strings.HasSuffix(k, "manifest.json") && f.manifest != nil {
			return &api.CacheHit{Key: k, DownloadURL: "mem://manifest"}, nil
		}
		if b, ok := f.store[k]; ok {
			return &api.CacheHit{Key: k, Size: int64(len(b)), DownloadURL: "mem://" + k}, nil
		}
	}
	return nil, nil
}

func (f *cacheFlowCP) PostArtifact(ctx context.Context, jobID int64, localPath, path, destination string) (*api.ArtifactInfo, error) {
	b, err := os.ReadFile(localPath)
	if err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.artifacts[path] = string(b)
	return &api.ArtifactInfo{ID: 1, Path: path, Destination: &destination, Size: int64(len(b))}, nil
}

func (f *cacheFlowCP) Download(ctx context.Context, rawURL, destPath string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	var b []byte
	switch {
	case strings.HasPrefix(rawURL, "mem://manifest"):
		b, _ = json.Marshal(f.manifest)
	default:
		key := strings.TrimPrefix(rawURL, "mem://")
		b = f.store[key]
	}
	if b == nil {
		return fmt.Errorf("no content for %s", rawURL)
	}
	return os.WriteFile(destPath, b, 0o644)
}

func (f *cacheFlowCP) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	return nil
}

// The fake docker exec must run tar INSIDE the "container" (locally) for
// these flows; the shared fake runs exec argv directly, which does exactly
// that — with -C workdir relative to a temp root we control via the claim's
// working_directory... which docker-exec would resolve inside the container.
// For the flow test we pre-create the workdir on the host at /root/project
// only if writable; instead we use a claim with working_directory pointing
// at a host temp dir (the fake docker executes locally, so it works).
func cacheFlowClaim(t *testing.T, workdir string, steps string) *payload.Claim {
	t.Helper()
	claimJSON := fmt.Sprintf(`{
      "id": 40, "name": "flows", "working_directory": %q,
      "executor": {"image": "fake"},
      "steps": %s,
      "pipeline": {"branch": "main"},
      "trusted": true, "workflow_run_id": 77, "project_id": 12
    }`, workdir, steps)
	c, err := payload.ParseClaim([]byte(claimJSON))
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestCacheSaveRestoreFlow(t *testing.T) {
	bin, _ := fakeDocker(t)
	cfg := testCfg(bin)
	workdir := t.TempDir()
	os.WriteFile(filepath.Join(workdir, "Gemfile.lock"), []byte("content-to-checksum"), 0o644)
	os.MkdirAll(filepath.Join(workdir, "vendor/bundle"), 0o755)
	os.WriteFile(filepath.Join(workdir, "vendor/bundle/gem.bin"), []byte("gem-bytes"), 0o644)

	cp := newCacheFlowCP(t)
	claim := cacheFlowClaim(t, workdir, `[
      {"type": "save_cache", "key": "gems-{{ checksum \"Gemfile.lock\" }}", "paths": ["vendor/bundle"]},
      {"type": "restore_cache", "keys": ["gems-{{ checksum \"Gemfile.lock\" }}", "gems-"]}
    ]`)
	e := New(cfg, cp, claim)
	status, results := e.Execute(func() bool { return false }, func() bool { return false })

	if status != StatusSuccess {
		t.Fatalf("status %s; log unavailable", status)
	}
	if len(results) != 2 || results[0].ExitCode != 0 || results[1].ExitCode != 0 {
		t.Fatalf("results: %+v", results)
	}
	keys := cpKeys(cp)
	if len(keys) != 1 || !strings.HasPrefix(keys[0], "gems-") || keys[0] == "gems-" {
		t.Fatalf("saved keys: %v (checksum must have resolved)", keys)
	}
	// The stored tarball contains the file (round trip via fake CP + local tar).
	b := cp.store[keys[0]]
	if len(b) == 0 {
		t.Fatal("stored tarball empty")
	}
}

func TestCacheRestoreMissIsClean(t *testing.T) {
	bin, _ := fakeDocker(t)
	cfg := testCfg(bin)
	workdir := t.TempDir()
	cp := newCacheFlowCP(t) // empty store
	claim := cacheFlowClaim(t, workdir, `[
      {"type": "restore_cache", "keys": ["nothing-matches"]}
    ]`)
	e := New(cfg, cp, claim)
	status, results := e.Execute(func() bool { return false }, func() bool { return false })
	if status != StatusSuccess {
		t.Fatalf("status %s", status)
	}
	if len(results) != 1 || results[0].ExitCode != 0 {
		t.Fatalf("results: %+v", results)
	}
}

func TestWorkspacePersistAttachFlow(t *testing.T) {
	bin, _ := fakeDocker(t)
	cfg := testCfg(bin)
	workdir := t.TempDir()
	os.MkdirAll(filepath.Join(workdir, "build"), 0o755)
	os.WriteFile(filepath.Join(workdir, "build/out.bin"), []byte("built-output"), 0o644)

	cp := newCacheFlowCP(t)
	claim := cacheFlowClaim(t, workdir, `[
      {"type": "persist_to_workspace", "root": ".", "paths": ["build"]},
      {"type": "attach_workspace", "at": "attached"}
    ]`)
	e := New(cfg, cp, claim)
	status, _ := e.Execute(func() bool { return false }, func() bool { return false })
	if status != StatusSuccess {
		t.Fatalf("status %s", status)
	}
	// The manifest was persisted and lists the root.
	cp.mu.Lock()
	defer cp.mu.Unlock()
	if len(cp.manifest) != 1 || cp.manifest[0] != "." {
		t.Fatalf("manifest: %v", cp.manifest)
	}
	if _, ok := cp.store["forge-ci-workspace/77/root.tgz"]; !ok {
		t.Fatalf("root tarball not stored: %v", keysOf(cp.store))
	}
}

func TestStoreArtifactsFlow(t *testing.T) {
	bin, _ := fakeDocker(t)
	cfg := testCfg(bin)
	workdir := t.TempDir()
	os.MkdirAll(filepath.Join(workdir, "tmp/capybara"), 0o755)
	os.WriteFile(filepath.Join(workdir, "tmp/capybara/shot-1.png"), []byte("png-one"), 0o644)
	os.WriteFile(filepath.Join(workdir, "tmp/capybara/shot-2.png"), []byte("png-two"), 0o644)

	cp := newCacheFlowCP(t)
	claim := cacheFlowClaim(t, workdir, `[
      {"type": "store_artifacts", "path": "tmp/capybara", "destination": "screenshots"}
    ]`)
	e := New(cfg, cp, claim)
	status, _ := e.Execute(func() bool { return false }, func() bool { return false })
	if status != StatusSuccess {
		t.Fatalf("status %s", status)
	}
	cp.mu.Lock()
	defer cp.mu.Unlock()
	for _, p := range []string{"tmp/capybara/shot-1.png", "tmp/capybara/shot-2.png"} {
		if got, ok := cp.artifacts[p]; !ok || got == "" {
			t.Errorf("artifact %s missing (have %v)", p, cp.artifacts)
		}
	}
	if cp.artifacts["tmp/capybara/shot-1.png"] != "png-one" {
		t.Error("artifact content mismatch")
	}
}

func cpKeys(cp *cacheFlowCP) []string {
	cp.mu.Lock()
	defer cp.mu.Unlock()
	out := make([]string, 0, len(cp.store))
	for k := range cp.store {
		out = append(out, k)
	}
	return out
}

func keysOf(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
