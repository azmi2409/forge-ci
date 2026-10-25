package logstream

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/redact"
)

// fakePoster records posted chunks with their seq.
type fakePoster struct {
	mu     sync.Mutex
	chunks []string
	seqs   []int64
	// fail controls failing behavior: failEvery N first calls fail.
	failRemaining int
	failErr       error
	posted        chan struct{}
}

func newFakePoster() *fakePoster {
	return &fakePoster{posted: make(chan struct{}, 1024)}
}

func (f *fakePoster) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	f.mu.Lock()
	if f.failRemaining > 0 {
		f.failRemaining--
		f.mu.Unlock()
		return f.failErr
	}
	f.chunks = append(f.chunks, chunk)
	f.seqs = append(f.seqs, seq)
	f.mu.Unlock()
	f.posted <- struct{}{}
	return nil
}

func (f *fakePoster) all() (string, []int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.chunks, ""), f.seqs
}

func (f *fakePoster) waitPosted(n int, timeout time.Duration) bool {
	deadline := time.After(timeout)
	for i := 0; i < n; i++ {
		select {
		case <-f.posted:
		case <-deadline:
			return false
		}
	}
	return true
}

func newStreamer(p ChunkPoster, secret string, chunkSize int, flush time.Duration) *Streamer {
	r := redact.New(map[string]string{"SECRET": secret}, len(secret))
	s := New(p, 1042, r, chunkSize, flush)
	s.StartTimer()
	return s
}

func TestChunkSplittingAndOrder(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "no-secrets-here", 16, 0)
	defer s.Close()

	payload := strings.Repeat("abcdefgh", 20) // 160 bytes
	s.Write([]byte(payload))
	if !p.waitPosted(10, 2*time.Second) {
		t.Fatal("chunks not posted")
	}
	s.Close()
	out, seqs := p.all()
	// Chunk boundaries shift for the retained tail; what matters is exact
	// reassembly and strictly increasing seqs from 0.
	if len(out) != len(payload) || out != payload {
		t.Fatalf("reassembly: got %d bytes, %q", len(out), out)
	}
	if len(seqs) == 0 {
		t.Fatal("no chunks")
	}
	for i, seq := range seqs {
		if seq != int64(i) {
			t.Fatalf("seq %d at position %d", seq, i)
		}
	}
}

func TestSimpleRedaction(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "s3cr3t-value-long", 4096, 0)
	defer s.Close()

	s.Write([]byte("token=s3cr3t-value-long ok\n"))
	if !p.waitPosted(1, 2*time.Second) {
		t.Fatal("chunk not posted")
	}
	s.Close()
	out, _ := p.all()
	if !strings.Contains(out, "[REDACTED]") || strings.Contains(out, "s3cr3t") {
		t.Fatalf("output leaked secret: %q", out)
	}
}

func TestSecretSplitAcrossWrites(t *testing.T) {
	p := newFakePoster()
	secret := "TOPSECRETVALUE123"
	s := newStreamer(p, secret, 4096, 0)
	defer s.Close()

	// Split the secret mid-way across two Writes.
	s.Write([]byte("head " + secret[:6]))
	s.Write([]byte(secret[6:] + " tail\n"))
	s.Close()
	out, _ := p.all()
	if strings.Contains(out, "TOPSECRET") || strings.Contains(out, "SECRETVALUE") {
		t.Fatalf("split secret leaked: %q", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Fatalf("secret never redacted: %q", out)
	}
	// The surrounding text survives.
	if !strings.Contains(out, "head ") || !strings.Contains(out, " tail\n") {
		t.Fatalf("context lost: %q", out)
	}
}

func TestSecretSplitAcrossTimerFlush(t *testing.T) {
	p := newFakePoster()
	secret := "LONGSECRETVALUE99"
	s := New(p, 1042, redact.New(map[string]string{"S": secret}, len(secret)), 4096, time.Hour)
	s.StartTimer()
	defer s.Close()

	// A manual timer-flush-equivalent (non-forced) must not expose the tail.
	s.Write([]byte("x " + secret[:8]))
	s.flush(false) // what the timer does
	s.Write([]byte(secret[8:] + " y"))
	s.Close()
	out, _ := p.all()
	if strings.Contains(out, secret) || strings.Contains(out, secret[:8]) || strings.Contains(out, secret[8:]) {
		t.Fatalf("secret leaked across flush boundary: %q", out)
	}
	if !strings.Contains(out, "[REDACTED]") {
		t.Fatalf("never redacted: %q", out)
	}
}

func TestUTF8NotSplitAcrossChunks(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 10, 0)
	defer s.Close()

	// "héllo" with é as 2 bytes: 6 bytes per repetition.
	payload := strings.Repeat("héllo", 4) // 24 bytes
	s.Write([]byte(payload))
	s.Close()
	out, _ := p.all()
	if strings.Count(out, "é") != 4 {
		t.Fatalf("multi-byte chars corrupted: %q", out)
	}
	if strings.Contains(out, "\uFFFD") {
		t.Fatalf("valid UTF-8 became U+FFFD: %q", out)
	}
}

func TestInvalidUTF8BecomesReplacementChar(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 4096, 0)
	defer s.Close()

	s.Write([]byte{'o', 'k', 0xFF, '\n'}) // 0xFF is invalid UTF-8
	s.Close()
	out, _ := p.all()
	if !strings.Contains(out, "\uFFFD") {
		t.Fatalf("invalid byte not replaced: %q", out)
	}
	if strings.ContainsRune(out, '\u00FF') {
		t.Fatalf("raw invalid byte passed through: %q", out)
	}
}

func TestSeqReusedOnRetry(t *testing.T) {
	p := newFakePoster()
	p.mu.Lock()
	p.failRemaining = 2 // two failures, third attempt succeeds
	p.failErr = errors.New("control plane down")
	p.mu.Unlock()

	s := newStreamer(p, "nosecrets", 4096, 0)
	// Long enough that the whole text is emitted as one chunk despite the
	// retention tail.
	text := "first chunk " + strings.Repeat("x", 100) + "\n"
	s.Write([]byte(text))
	if !p.waitPosted(1, 5*time.Second) {
		t.Fatal("chunk never posted after retries")
	}
	s.Close()
	out, seqs := p.all()
	if len(seqs) < 1 || seqs[0] != 0 {
		t.Fatalf("first chunk must have seq 0: %v", seqs)
	}
	// seq 0 posted exactly once (retries reused it).
	zeroes := 0
	for _, q := range seqs {
		if q == 0 {
			zeroes++
		}
	}
	if zeroes != 1 {
		t.Fatalf("seq 0 posted %d times; retries must reuse it", zeroes)
	}
	if !strings.Contains(out, "first chunk") {
		t.Fatalf("content lost: %q", out)
	}
	// The next chunk continues the sequence.
	s2 := newStreamer(p, "nosecrets", 4096, 0)
	defer s2.Close()
	s2.Write([]byte("second " + strings.Repeat("y", 100) + "\n"))
	if !p.waitPosted(2, 2*time.Second) {
		t.Fatal("second chunk not posted")
	}
	s2.Close()
	_, seqs = p.all()
	if len(seqs) < 2 || seqs[len(seqs)-2] != 1 && seqs[len(seqs)-1] != 1 {
		t.Fatalf("seqs after retry must continue from 1: %v", seqs)
	}
}

func TestRetriesThenDrops(t *testing.T) {
	p := newFakePoster()
	p.mu.Lock()
	p.failRemaining = 1 << 30 // always fail
	p.failErr = errors.New("down")
	p.mu.Unlock()

	s := newStreamer(p, "nosecrets", 4096, 0)
	s.Write([]byte("will be dropped\n"))
	s.Close() // must return (3 attempts, two 1s delays), not hang
	// Nothing was posted; the drop was noted on stderr.
	p.mu.Lock()
	n := len(p.chunks)
	p.mu.Unlock()
	if n != 0 {
		t.Fatalf("dropped chunk was posted: %d", n)
	}
}

func TestCloseDrainsEverything(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 32, 0)

	var total int
	for i := 0; i < 100; i++ {
		line := fmt.Sprintf("line-%03d padded to exceed chunk boundaries some more\n", i)
		total += len(line)
		s.Write([]byte(line))
	}
	s.Close()
	out, _ := p.all()
	if len(out) != total {
		t.Fatalf("close must drain all bytes: got %d want %d", len(out), total)
	}
}

func TestBoundedBackpressure(t *testing.T) {
	p := newFakePoster()
	// 8MB queue / 64KB chunks = 128 capacity; flood far beyond it with a
	// paused poster and confirm Write blocks rather than growing memory.
	s := newStreamer(p, "nosecrets", 65536, 0)

	gate := make(chan struct{})
	p2 := &gatedPoster{inner: p, gate: gate}
	_ = s
	s2 := New(p2, 1042, redact.New(nil, 8), 65536, 0)

	done := make(chan struct{})
	go func() {
		for i := 0; i < 200; i++ { // 200 * 64KB = 12.8MB > 8MB queue
			s2.Write([]byte(strings.Repeat("x", 65536)))
		}
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("write completed despite a paused consumer — backpressure not applied")
	case <-time.After(300 * time.Millisecond):
		// Still blocked: correct backpressure.
	}
	close(gate)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("write never completed after unblocking")
	}
	s2.Close()
}

type gatedPoster struct {
	inner ChunkPoster
	gate  chan struct{}
}

func (g *gatedPoster) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	<-g.gate
	return g.inner.PostLogChunk(ctx, jobID, seq, chunk)
}

func TestConcurrentWritersNoLoss(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 4096, 0)

	var wg sync.WaitGroup
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				s.Write([]byte(fmt.Sprintf("w%d-i%03d\n", w, i)))
			}
		}(w)
	}
	wg.Wait()
	s.Close()

	out, _ := p.all()
	for w := 0; w < 8; w++ {
		for i := 0; i < 50; i++ {
			if !strings.Contains(out, fmt.Sprintf("w%d-i%03d\n", w, i)) {
				t.Fatalf("lost write w%d i%d", w, i)
			}
		}
	}
}

func TestLastWriteUpdates(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 4096, 0)
	defer s.Close()
	first := s.LastWrite()
	time.Sleep(20 * time.Millisecond)
	s.Write([]byte("tick\n"))
	if !s.LastWrite().After(first) {
		t.Fatal("LastWrite must advance on bytes received")
	}
}

func TestWriteAfterCloseIgnored(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 4096, 0)
	s.Write([]byte("before close\n"))
	s.Close()
	s.Write([]byte("after close\n")) // must not block or panic
	out, _ := p.all()
	if strings.Contains(out, "after close") {
		t.Fatal("post-close write was posted")
	}
	if !strings.Contains(out, "before close") {
		t.Fatal("pre-close write lost")
	}
}

func TestCloseIdempotent(t *testing.T) {
	p := newFakePoster()
	s := newStreamer(p, "nosecrets", 4096, 0)
	s.Write([]byte("once\n"))
	s.Close()
	s.Close()
	s.Close()
	out, _ := p.all()
	if out != "once\n" {
		t.Fatalf("idempotent close changed output: %q", out)
	}
}

func TestTimerFlushEmitsLiveWithoutTail(t *testing.T) {
	p := newFakePoster()
	// Long flush interval, but we call flush(false) directly to stand in
	// for the timer: a partial line shorter than the retention must NOT be
	// emitted prematurely.
	secret := "SHORTSECRET-XYZ"
	s := New(p, 1042, redact.New(map[string]string{"S": secret}, len(secret)), 4096, time.Hour)
	s.StartTimer()
	defer s.Close()

	s.Write([]byte("ab")) // 2 bytes, retention is len-1 = 14 -> nothing emittable
	s.flush(false)
	p.mu.Lock()
	n := len(p.chunks)
	p.mu.Unlock()
	if n != 0 {
		t.Fatalf("timer flush exposed the retained tail (%d chunks): %q", n, p.chunks)
	}
	s.Write([]byte("cd\n"))
	s.Close()
	out, _ := p.all()
	if out != "abcd\n" {
		t.Fatalf("close must emit the tail: %q", out)
	}
}
