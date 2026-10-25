package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "contract", name))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	return b
}

// fakeCP is a control plane fake recording requests and bodies per path.
type fakeCP struct {
	t        *testing.T
	Server   *httptest.Server
	mu       sync.Mutex
	requests map[string][]*http.Request
	handler  func(w http.ResponseWriter, r *http.Request) bool // true = handled
}

func newFakeCP(t *testing.T, handler func(w http.ResponseWriter, r *http.Request) bool) *fakeCP {
	t.Helper()
	cp := &fakeCP{t: t, requests: map[string][]*http.Request{}, handler: handler}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cp.mu.Lock()
		cp.requests[r.URL.Path] = append(cp.requests[r.URL.Path], r)
		cp.mu.Unlock()
		// The body is left for the handler — it is the only reader.
		if handler != nil && handler(w, r) {
			return
		}
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, `{"error": "unexpected path"}`)
	}))
	cp.Server = srv
	t.Cleanup(srv.Close)
	return cp
}

func (cp *fakeCP) URL() string { return cp.Server.URL }

func (cp *fakeCP) count(path string) int {
	cp.mu.Lock()
	defer cp.mu.Unlock()
	return len(cp.requests[path])
}

func (cp *fakeCP) header(path string, i int, name string) string {
	cp.mu.Lock()
	defer cp.mu.Unlock()
	return cp.requests[path][i].Header.Get(name)
}

func clientFor(t *testing.T, url string) *Client {
	t.Helper()
	c := New(url, "test-token-12345678")
	t.Cleanup(c.CloseIdleConnections)
	return c
}

func TestAuthAndAcceptHeaders(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		fmt.Fprint(w, `{"id":1042,"status":"running"}`)
		return true
	})
	c := clientFor(t, cp.URL())
	ctx := context.Background()
	if err := c.Start(ctx, 1042); err != nil {
		t.Fatal(err)
	}
	if got := cp.header("/api/v1/runner/jobs/1042/start", 0, "Authorization"); got != "Bearer test-token-12345678" {
		t.Fatalf("auth header: %q", got)
	}
	if got := cp.header("/api/v1/runner/jobs/1042/start", 0, "Accept"); got != "application/json" {
		t.Fatalf("accept header: %q", got)
	}
}

func TestClaimFullFixture(t *testing.T) {
	var claimBody string
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		b, _ := io.ReadAll(r.Body)
		claimBody = string(b)
		w.Write(fixture(t, "claim-full.json"))
		return true
	})
	c := clientFor(t, cp.URL())
	claim, upcoming, err := c.Claim(context.Background(), "")
	if err != nil || claim == nil || upcoming != 0 {
		t.Fatalf("claim: %v upcoming=%d", err, upcoming)
	}
	if claim.ID != 1042 || !claim.TrustedPipeline() || claim.Repository.Token == nil {
		t.Fatalf("payload: %+v", claim)
	}
	// Classless runner sends {}.
	if claimBody != "{}" {
		t.Fatalf("classless claim body: %s", claimBody)
	}
}

func TestClaimWithResourceClass(t *testing.T) {
	var claimBody string
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		b, _ := io.ReadAll(r.Body)
		claimBody = string(b)
		w.Write(fixture(t, "claim-full.json"))
		return true
	})
	c := clientFor(t, cp.URL())
	if _, _, err := c.Claim(context.Background(), "medium"); err != nil {
		t.Fatal(err)
	}
	if claimBody != `{"resource_class":"medium"}` {
		t.Fatalf("claim body: %s", claimBody)
	}
}

func TestClaimIdleAndUpcoming(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(http.StatusUnprocessableEntity)
		w.Write(fixture(t, "claim-upcoming-422.json"))
		return true
	})
	c := clientFor(t, cp.URL())
	claim, upcoming, err := c.Claim(context.Background(), "medium")
	if !errors.Is(err, ErrIdle) || claim != nil || upcoming != 3 {
		t.Fatalf("err=%v claim=%v upcoming=%d", err, claim, upcoming)
	}
}

func TestClaimIdleWithoutUpcomingKey(t *testing.T) {
	// Older servers send 422 without `upcoming` — treated as 0.
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(http.StatusUnprocessableEntity)
		fmt.Fprint(w, `{"error":"no claimable jobs right now"}`)
		return true
	})
	c := clientFor(t, cp.URL())
	_, upcoming, err := c.Claim(context.Background(), "")
	if !errors.Is(err, ErrIdle) || upcoming != 0 {
		t.Fatalf("err=%v upcoming=%d", err, upcoming)
	}
}

func TestClaimUnauthorized(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(http.StatusUnauthorized)
		w.Write(fixture(t, "claim-unauthorized-401.json"))
		return true
	})
	c := clientFor(t, cp.URL())
	_, _, err := c.Claim(context.Background(), "")
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("err=%v", err)
	}
}

// lifecycleSrv serves the right sub-object of lifecycle-ok.json per path.
func lifecycleSrv(t *testing.T, record func(path, body string)) *fakeCP {
	var lk struct {
		Start            map[string]any `json:"start"`
		HeartbeatRunning map[string]any `json:"heartbeat_running"`
		HeartbeatCancel  map[string]any `json:"heartbeat_canceled"`
		Complete         map[string]any `json:"complete"`
		Release          map[string]any `json:"release"`
	}
	if err := json.Unmarshal(fixture(t, "lifecycle-ok.json"), &lk); err != nil {
		t.Fatal(err)
	}
	write := func(w http.ResponseWriter, v any) {
		b, _ := json.Marshal(v)
		w.Write(b)
	}
	return newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		body, _ := io.ReadAll(r.Body)
		if record != nil {
			record(r.URL.Path, string(body))
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/heartbeat"):
			write(w, lk.HeartbeatRunning)
		case strings.HasSuffix(r.URL.Path, "/start"):
			write(w, lk.Start)
		case strings.HasSuffix(r.URL.Path, "/complete"):
			write(w, lk.Complete)
		case strings.HasSuffix(r.URL.Path, "/release"):
			write(w, lk.Release)
		default:
			write(w, map[string]any{})
		}
		return true
	})
}

func TestLifecycleRoundTrip(t *testing.T) {
	var bodies sync.Map
	cp := lifecycleSrv(t, func(path, body string) { bodies.Store(path, body) })
	c := clientFor(t, cp.URL())
	ctx := context.Background()

	if err := c.Start(ctx, 1042); err != nil {
		t.Fatalf("start: %v", err)
	}
	reply, err := c.Heartbeat(ctx, 1042)
	if err != nil || reply.Status != "running" {
		t.Fatalf("heartbeat: %v %+v", err, reply)
	}
	if err := c.Complete(ctx, 1042, "success", []StepResult{
		{Name: "checkout", ExitCode: 0, StartedAt: "2026-10-25T09:30:12Z", FinishedAt: "2026-10-25T09:30:13Z"},
	}); err != nil {
		t.Fatalf("complete: %v", err)
	}
	if err := c.Release(ctx, 1042, "runner shutting down (SIGTERM)"); err != nil {
		t.Fatalf("release: %v", err)
	}

	raw, _ := bodies.Load("/api/v1/runner/jobs/1042/complete")
	var parsed struct {
		Status      string       `json:"status"`
		StepResults []StepResult `json:"step_results"`
	}
	if err := json.Unmarshal([]byte(raw.(string)), &parsed); err != nil {
		t.Fatalf("complete body %v: %v", raw, err)
	}
	if parsed.Status != "success" || len(parsed.StepResults) != 1 || parsed.StepResults[0].Name != "checkout" {
		t.Fatalf("complete parsed: %+v", parsed)
	}
	reason, _ := bodies.Load("/api/v1/runner/jobs/1042/release")
	if !strings.Contains(reason.(string), "runner shutting down") {
		t.Fatalf("release body: %v", reason)
	}
}

func TestCompleteNilResultsSentAsEmptyArray(t *testing.T) {
	var got string
	cp := lifecycleSrv(t, func(path, body string) { got = body })
	c := clientFor(t, cp.URL())
	if err := c.Complete(context.Background(), 1042, "failed", nil); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, `"step_results":[]`) {
		t.Fatalf("nil step_results must encode as [], got %s", got)
	}
}

func TestHeartbeatCanceledReply(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		fmt.Fprint(w, `{"id":1042,"status":"canceled","heartbeat_at":"2026-10-25T09:30:42Z"}`)
		return true
	})
	c := clientFor(t, cp.URL())
	reply, err := c.Heartbeat(context.Background(), 1042)
	if err != nil || reply.Status != "canceled" {
		t.Fatalf("reply=%+v err=%v", reply, err)
	}
}

func TestReleaseConflict409(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":"job released 2 times already; not requeued"}`)
		return true
	})
	c := clientFor(t, cp.URL())
	err := c.Release(context.Background(), 1042, "shutting down")
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != 409 {
		t.Fatalf("err=%v", err)
	}
}

func TestStartIllegalTransition422(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		w.WriteHeader(http.StatusUnprocessableEntity)
		fmt.Fprint(w, `{"error":"cannot transition from canceled to running"}`)
		return true
	})
	c := clientFor(t, cp.URL())
	err := c.Start(context.Background(), 1042)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != 422 {
		t.Fatalf("err=%v", err)
	}
}

func TestPostLogChunkShape(t *testing.T) {
	var got string
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		b, _ := io.ReadAll(r.Body)
		got = string(b)
		fmt.Fprint(w, `{"job_id":1042,"seq":7}`)
		return true
	})
	c := clientFor(t, cp.URL())
	if err := c.PostLogChunk(context.Background(), 1042, 7, "hello\n"); err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Seq   int    `json:"seq"`
		Chunk string `json:"chunk"`
	}
	if err := json.Unmarshal([]byte(got), &parsed); err != nil || parsed.Seq != 7 || parsed.Chunk != "hello\n" {
		t.Fatalf("chunk body %s: err=%v parsed=%+v", got, err, parsed)
	}
}

func TestPutCacheMultipart(t *testing.T) {
	tgz := filepath.Join(t.TempDir(), "cache.tgz")
	if err := os.WriteFile(tgz, []byte("fake-tarball-bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	contentLength := ""
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		contentLength = r.Header.Get("Content-Length")
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Errorf("multipart parse: %v", err)
			w.WriteHeader(422)
			return true
		}
		if r.FormValue("key") != "gems-v1-abc" {
			t.Errorf("key field: %q", r.FormValue("key"))
		}
		file, hdr, err := r.FormFile("file")
		if err != nil {
			t.Errorf("file part: %v", err)
			return true
		}
		defer file.Close()
		data, _ := io.ReadAll(file)
		if string(data) != "fake-tarball-bytes" || hdr.Filename != "cache.tgz" {
			t.Errorf("file part: %q %q", hdr.Filename, data)
		}
		fmt.Fprint(w, `{"key":"gems-v1-abc","size":18}`)
		return true
	})
	c := clientFor(t, cp.URL())
	hit, err := c.PutCache(context.Background(), 12, "gems-v1-abc", tgz)
	if err != nil || hit.Key != "gems-v1-abc" || hit.Size != 18 {
		t.Fatalf("hit=%+v err=%v", hit, err)
	}
	if contentLength == "" {
		t.Fatal("Content-Length missing — request was chunked")
	}
}

func TestGetCacheHitMissForbidden(t *testing.T) {
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		switch r.URL.Query().Get("keys[]") {
		case "k1":
			fmt.Fprint(w, `{"key":"k1","size":5,"download_url":"http://x/y"}`)
		case "forbidden":
			w.WriteHeader(http.StatusForbidden)
			fmt.Fprint(w, `{"error":"forbidden: token has no active job in this project"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"error":"no matching cache entry"}`)
		}
		return true
	})
	c := clientFor(t, cp.URL())
	ctx := context.Background()

	hit, err := c.GetCache(ctx, 12, []string{"k1", "k2"})
	if err != nil || hit == nil || hit.Key != "k1" {
		t.Fatalf("hit=%+v err=%v", hit, err)
	}
	if hit, err := c.GetCache(ctx, 12, []string{"miss"}); err != nil || hit != nil {
		t.Fatalf("miss: hit=%v err=%v", hit, err)
	}
	// 403 reads as a clean miss (runner without an active job).
	if hit, err := c.GetCache(ctx, 12, []string{"forbidden"}); err != nil || hit != nil {
		t.Fatalf("forbidden: hit=%v err=%v", hit, err)
	}
}

func TestPostArtifactDestinationOmittedAndNullPinned(t *testing.T) {
	f := filepath.Join(t.TempDir(), "shot.png")
	os.WriteFile(f, []byte("png-bytes"), 0o644)
	cp := newFakeCP(t, func(w http.ResponseWriter, r *http.Request) bool {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Errorf("multipart: %v", err)
		}
		if r.FormValue("destination") != "" {
			t.Errorf("empty destination must be omitted, got %q", r.FormValue("destination"))
		}
		if r.FormValue("path") != "tmp/shot.png" {
			t.Errorf("path: %q", r.FormValue("path"))
		}
		// The server sends destination null when unset (fixture-pinned).
		w.WriteHeader(http.StatusCreated)
		w.Write(fixture(t, "artifact-created-201.json"))
		return true
	})
	c := clientFor(t, cp.URL())
	info, err := c.PostArtifact(context.Background(), 1042, f, "tmp/shot.png", "")
	if err != nil {
		t.Fatal(err)
	}
	if info.Destination != nil {
		t.Fatalf("destination must decode as nil for JSON null, got %q", *info.Destination)
	}
	if info.ID != 556 {
		t.Fatalf("id: %d", info.ID)
	}
}

func TestDownloadRedirectsAndScheme(t *testing.T) {
	hops := 0
	var srvURL string
	var srv *httptest.Server
	srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hops++
		switch {
		case r.URL.Path == "/final":
			fmt.Fprint(w, "the-tarball-bytes")
		case r.URL.Path == "/loop":
			http.Redirect(w, r, srvURL+"/loop", http.StatusFound)
		case r.URL.Path == "/bad-scheme":
			http.Redirect(w, r, "ftp://evil/x", http.StatusFound)
		case r.URL.Path == "/r2":
			// Third redirect: /start -> /r1 -> /r2 -> /final.
			http.Redirect(w, r, srvURL+"/final", http.StatusFound)
		case r.URL.Path == "/r1":
			http.Redirect(w, r, srvURL+"/r2", http.StatusFound)
		default:
			http.Redirect(w, r, srvURL+"/r1", http.StatusFound)
		}
	}))
	srvURL = srv.URL
	defer srv.Close()

	c := clientFor(t, "http://unused.local")
	dest := filepath.Join(t.TempDir(), "out.tgz")

	if err := c.Download(context.Background(), srvURL+"/start", dest); err != nil {
		t.Fatalf("download: %v", err)
	}
	// /start, /r1, /r2, /final — exactly three redirects followed.
	if hops != 4 {
		t.Fatalf("requests made: %d", hops)
	}
	b, _ := os.ReadFile(dest)
	if string(b) != "the-tarball-bytes" {
		t.Fatalf("content: %q", b)
	}
	if _, err := os.Stat(dest + ".part"); !os.IsNotExist(err) {
		t.Fatal(".part file left behind")
	}

	err := c.Download(context.Background(), srvURL+"/loop", filepath.Join(t.TempDir(), "x"))
	if err == nil || !strings.Contains(err.Error(), "too many redirects") {
		t.Fatalf("loop err=%v", err)
	}
	err = c.Download(context.Background(), srvURL+"/bad-scheme", filepath.Join(t.TempDir(), "y"))
	if err == nil || !strings.Contains(err.Error(), "unsupported redirect scheme") {
		t.Fatalf("scheme err=%v", err)
	}
	err = c.Download(context.Background(), "file:///etc/passwd", filepath.Join(t.TempDir(), "z"))
	if err == nil || !strings.Contains(err.Error(), "unsupported download scheme") {
		t.Fatalf("direct scheme err=%v", err)
	}
}

func TestDownloadFailureLeavesNoPartialFile(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprint(w, `{"error":"boom"}`)
	}))
	defer srv.Close()
	c := clientFor(t, "http://unused.local")
	dest := filepath.Join(t.TempDir(), "out.bin")
	err := c.Download(context.Background(), srv.URL, dest)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != 500 {
		t.Fatalf("err=%v", err)
	}
	for _, p := range []string{dest, dest + ".part"} {
		if _, statErr := os.Stat(p); !os.IsNotExist(statErr) {
			t.Fatalf("%s exists after failed download", p)
		}
	}
}

// Timeout semantics: a healthy long transfer must NOT be killed by a short
// total deadline (this body takes ~600ms, longer than any JSON deadline).
func TestDownloadSlowTransferSucceeds(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		flusher := w.(http.Flusher)
		for i := 0; i < 4; i++ {
			fmt.Fprint(w, strings.Repeat("x", 4096))
			flusher.Flush()
			time.Sleep(150 * time.Millisecond)
		}
	}))
	defer srv.Close()
	c := clientFor(t, "http://unused.local")
	dest := filepath.Join(t.TempDir(), "slow.bin")
	start := time.Now()
	if err := c.Download(context.Background(), srv.URL, dest); err != nil {
		t.Fatalf("slow transfer must succeed: %v", err)
	}
	if time.Since(start) < 500*time.Millisecond {
		t.Fatal("transfer finished suspiciously fast")
	}
}

func TestNoRedirectFollowedOnAuthenticatedClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/elsewhere", http.StatusFound)
	}))
	defer srv.Close()
	c := clientFor(t, srv.URL)
	err := c.Start(context.Background(), 1)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != http.StatusFound {
		t.Fatalf("authenticated client must not follow redirects, err=%v", err)
	}
}
