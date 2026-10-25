// Package logstream buffers job output, redacts secrets, and posts
// seq-numbered chunks to the control plane in order.
//
// Correctness rules (frozen in runner-go/CONTRACT.md):
//
//   - Raw bytes are buffered un-redacted; the WHOLE buffer is redacted
//     before any of it is emitted, so a secret is never caught half-split.
//   - Emission stops maxSecretLen-1 bytes short of the live tail unless the
//     stream is closing: a secret split across read boundaries is completed
//     by later bytes while it sits in the retained suffix. Periodic timer
//     flushes pass through the same retention — they can never expose the
//     tail prematurely. Only Close emits the final tail (redacted whole).
//   - Emission backs off to a UTF-8 boundary so valid multi-byte characters
//     are never split across chunks; bytes that are invalid UTF-8 to begin
//     with are replaced with U+FFFD at POST time (before JSON encoding).
//   - Sequence numbers are assigned in extraction order under the same lock
//     that extracts, and a retried POST reuses its seq (the server upserts
//     on job_id+seq). Retries: 3 total attempts, two 1-second delays, then
//     the chunk is dropped with a stderr note — like the Ruby runner.
//   - One sender goroutine posts everything, so chunks reach the server in
//     seq order. The queue is bounded (~8MB); a slow control plane applies
//     backpressure to producers (Write blocks) instead of growing memory.
//   - Close stops producers, emits the tail, lets in-flight sends land,
//     drains the sender, and only then returns — terminal reporting
//     (complete) happens strictly after Close.
package logstream

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/azmi2409/forge-ci/runner-go/internal/redact"
)

// ChunkPoster is the slice of the control-plane client the streamer needs.
type ChunkPoster interface {
	PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error
}

const (
	// MaxQueueBytes bounds queued-but-unposted output; producers block
	// beyond it (backpressure instead of unbounded memory).
	MaxQueueBytes = 8 << 20
	// postAttempts total POST tries per chunk, with postRetryDelay between
	// them (3 attempts, two 1s delays — matching the Ruby runner).
	postAttempts   = 3
	postRetryDelay = time.Second
)

type chunk struct {
	seq   int64
	bytes string
}

type Streamer struct {
	client     ChunkPoster
	jobID      int64
	redactor   *redact.Redactor
	chunkSize  int
	flushEvery time.Duration

	mu                sync.Mutex
	buffer            []byte
	seq               int64
	closed            bool
	lastWriteUnixNano int64

	outbound  chan chunk // bounded; single sender drains it in order
	done      chan struct{}
	closeDone chan struct{}
	flusher   *time.Ticker
	wg        sync.WaitGroup // in-flight producers (blocked or sending)
	closeOnce sync.Once
}

func New(client ChunkPoster, jobID int64, redactor *redact.Redactor, chunkSize int, flushEvery time.Duration) *Streamer {
	if chunkSize <= 0 {
		chunkSize = 65536
	}
	capacity := MaxQueueBytes / chunkSize
	if capacity < 1 {
		capacity = 1
	}
	s := &Streamer{
		client:     client,
		jobID:      jobID,
		redactor:   redactor,
		chunkSize:  chunkSize,
		flushEvery: flushEvery,
		outbound:   make(chan chunk, capacity),
		done:       make(chan struct{}),
		closeDone:  make(chan struct{}),
	}
	s.lastWriteUnixNano = time.Now().UnixNano()
	go s.sender()
	return s
}

// StartTimer runs the periodic flusher for live tailing. No-op without a
// flush interval.
func (s *Streamer) StartTimer() {
	if s.flushEvery <= 0 {
		return
	}
	s.mu.Lock()
	if s.flusher != nil || s.closed {
		s.mu.Unlock()
		return
	}
	s.flusher = time.NewTicker(s.flushEvery)
	s.mu.Unlock()
	go func() {
		for {
			select {
			case <-s.flusher.C:
				s.flush(false)
			case <-s.done:
				return
			}
		}
	}()
}

// Write buffers output. It blocks while the outbound queue is full
// (backpressure) and never fails: output that cannot be posted after
// retries is dropped with a note — it never fails a job.
func (s *Streamer) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return len(p), nil // post-close writes are dropped, not fatal
	}
	// Counted under the lock so Close's wg.Wait cannot slip past a producer
	// that has passed the closed-check.
	s.wg.Add(1)
	s.buffer = append(s.buffer, p...)
	s.lastWriteUnixNano = time.Now().UnixNano()
	chunks := s.extractLocked(false)
	s.mu.Unlock()

	defer s.wg.Done()
	// Blocking send: backpressure. The sender drains until Close's done,
	// which is only closed after every counted producer has landed.
	for _, c := range chunks {
		s.outbound <- c
	}
	return len(p), nil
}

// LastWrite is when output was last received — the executor's no-output
// watchdog consumes this (activity = bytes received, not newlines).
func (s *Streamer) LastWrite() time.Time {
	return time.Unix(0, s.lastWriteUnixNano)
}

// flush extracts and enqueues emittable bytes. With force (Close) everything
// goes, including the retained tail; without it the tail stays for
// boundary-safe redaction.
func (s *Streamer) flush(force bool) {
	s.mu.Lock()
	if s.closed && !force {
		s.mu.Unlock()
		return
	}
	s.wg.Add(1)
	chunks := s.extractLocked(force)
	s.mu.Unlock()

	defer s.wg.Done()
	for _, c := range chunks {
		s.outbound <- c
	}
}

// extractLocked redacts the whole buffer, then splits emittable bytes into
// chunkSize pieces, assigning seqs in order. Caller holds s.mu.
func (s *Streamer) extractLocked(force bool) []chunk {
	if len(s.buffer) == 0 {
		return nil
	}
	// Redact complete occurrences everywhere (including any crossing the
	// seam into the retained tail). Incomplete occurrences (extending past
	// the buffer end) can only begin within the last maxSecretLen-1 bytes,
	// which stay unemitted.
	buf := []byte(s.redactor.Redact(string(s.buffer)))

	keep := s.redactor.MaxSecretLen()
	if keep > 0 {
		keep-- // retained suffix length
	}
	cut := len(buf)
	if !force {
		cut -= keep
	}
	if cut <= 0 {
		return nil
	}
	if !force {
		cut = backUpToUTF8Boundary(buf, cut)
		if cut <= 0 {
			return nil
		}
	}

	var chunks []chunk
	for start := 0; start < cut; {
		end := start + s.chunkSize
		if end > cut {
			end = cut
		} else {
			// Split whole chunks on UTF-8 boundaries too.
			if backed := backUpToUTF8Boundary(buf, end); backed > start {
				end = backed
			}
		}
		s.seq++
		chunks = append(chunks, chunk{seq: s.seq - 1, bytes: sanitize(string(buf[start:end]))})
		start = end
	}
	s.buffer = append(s.buffer[:0], buf[cut:]...)
	return chunks
}

// backUpToUTF8Boundary moves cut left over UTF-8 continuation bytes so the
// emitted prefix ends on a character boundary.
func backUpToUTF8Boundary(buf []byte, cut int) int {
	for cut > 0 && cut < len(buf) && isUTF8Continuation(buf[cut]) {
		cut--
	}
	return cut
}

func isUTF8Continuation(b byte) bool { return b&0xC0 == 0x80 }

// sanitize replaces invalid UTF-8 with U+FFFD before JSON encoding.
func sanitize(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	return strings.ToValidUTF8(s, "\uFFFD")
}

// sender is the single ordered poster. It exits only after done is closed
// and the queue is drained.
func (s *Streamer) sender() {
	defer close(s.closeDone)
	for {
		select {
		case c := <-s.outbound:
			s.post(c)
		case <-s.done:
			for {
				select {
				case c := <-s.outbound:
					s.post(c)
				default:
					return
				}
			}
		}
	}
}

func (s *Streamer) post(c chunk) {
	ctx := context.Background()
	var err error
	for attempt := 0; attempt < postAttempts; attempt++ {
		if attempt > 0 {
			time.Sleep(postRetryDelay)
		}
		if err = s.client.PostLogChunk(ctx, s.jobID, c.seq, c.bytes); err == nil {
			return
		}
	}
	fmt.Fprintf(os.Stderr, "[forge-ci-runner] log chunk POST failed, dropping chunk (seq %d): %v\n", c.seq, err)
}

// Close stops producers and the flusher, emits everything (including the
// retained tail), lets in-flight sends land, drains the sender, and returns
// only when every chunk is posted or dropped. Terminal reporting must wait
// for Close. Idempotent.
func (s *Streamer) Close() {
	s.closeOnce.Do(func() {
		s.mu.Lock()
		s.closed = true
		s.mu.Unlock()

		if s.flusher != nil {
			s.flusher.Stop()
		}
		// Final tail. The sender is still running (done is open), so this
		// blocking send always drains.
		s.flush(true)
		// Let producers with in-flight sends finish enqueueing; after
		// closed=true no NEW chunks are extracted.
		s.wg.Wait()
		// Only now tell the sender to exit after draining.
		close(s.done)
		<-s.closeDone
	})
}
