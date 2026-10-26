// Package api is the HTTP client for the control plane Runner API, built
// exactly against the frozen contract in runner-go/CONTRACT.md — no
// invented endpoints. Timeout semantics are deliberate:
//
//   - JSON lifecycle calls take a whole-request deadline (small payloads).
//   - Multipart uploads take a longer whole-request deadline (tarballs are
//     big but bounded by the upload itself).
//   - Signed-URL downloads use transport-level timeouts (dial, response
//     header) and NEVER a total deadline that could kill a healthy long
//     transfer; callers bound them with context when needed.
//
// Retry policy lives with the callers: only log chunks are idempotent
// server-side (upsert on job_id+seq) and may be retried.
package api

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/azmi2409/forge-ci/runner-go/internal/payload"
)

// Deadlines per endpoint class (see package doc).
const (
	jsonCallTimeout    = 60 * time.Second
	uploadTimeout      = 10 * time.Minute
	dialTimeout        = 10 * time.Second
	tlsHandshakeTimout = 10 * time.Second
	respHeaderTimeout  = 60 * time.Second
	idleConnTimeout    = 90 * time.Second
	// Redirect cap for signed-URL downloads.
	maxRedirects = 3
)

// ErrUnauthorized marks a 401: the token is wrong and the runner must exit
// instead of backing off.
var ErrUnauthorized = errors.New("unauthorized")

// APIError is a non-2xx control-plane response.
type APIError struct {
	Code int
	Body string
}

func (e *APIError) Error() string {
	body := e.Body
	if len(body) > 200 {
		body = body[:200]
	}
	return fmt.Sprintf("HTTP %d: %s", e.Code, body)
}

// UpcomingError is the 422 claim response (nothing claimable now).
type UpcomingError struct {
	Upcoming int
	Body     string
}

func (e *UpcomingError) Error() string {
	return fmt.Sprintf("HTTP 422 (upcoming=%d): %s", e.Upcoming, e.Body)
}

type Client struct {
	base      string
	token     string
	runnerID  string
	hostname  string
	api       *http.Client // authenticated; redirects disabled
	download  *http.Client // unauthenticated; signed URLs only
	transport *http.Transport
}

func New(baseURL, token string) *Client {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		panic(fmt.Errorf("generate runner ID: %w", err))
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	hostname, err := os.Hostname()
	hostname = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r > 0x7e {
			return -1
		}
		return r
	}, hostname))
	if err != nil || hostname == "" {
		hostname = "unknown"
	}
	if len(hostname) > 255 {
		hostname = strings.TrimSpace(hostname[:255])
	}
	transport := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: dialTimeout}).DialContext,
		TLSHandshakeTimeout:   tlsHandshakeTimout,
		ResponseHeaderTimeout: respHeaderTimeout,
		IdleConnTimeout:       idleConnTimeout,
	}
	return &Client{
		base:      strings.TrimRight(baseURL, "/"),
		token:     token,
		runnerID:  fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:]),
		hostname:  hostname,
		transport: transport,
		api: &http.Client{
			Transport: transport,
			// Never follow a redirect with the auth header attached.
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		download: &http.Client{
			Transport: transport,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				// via includes the original request, so this allows exactly
				// maxRedirects redirects (matching the Ruby runner's limit).
				if len(via) > maxRedirects {
					return fmt.Errorf("too many redirects (stopped after %d)", maxRedirects)
				}
				if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
					return fmt.Errorf("unsupported redirect scheme %q", req.URL.Scheme)
				}
				return nil
			},
		},
	}

}

func (c *Client) CloseIdleConnections() { c.transport.CloseIdleConnections() }

// --- lifecycle (JSON) -------------------------------------------------------

// Claim posts the claim request. Returns (nil, 0, nil)-ish results:
//   - a claimed job,
//   - ErrIdle (with Upcoming) when the server answered 422,
//   - ErrUnauthorized (401) or another error otherwise.
var ErrIdle = errors.New("no claimable jobs")

func (c *Client) Claim(ctx context.Context, resourceClass string) (*payload.Claim, int, error) {
	body := map[string]any{}
	if resourceClass != "" {
		body["resource_class"] = resourceClass
	}
	respBody, err := c.postJSON(ctx, "/api/v1/runner/jobs/claim", body)
	if err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) {
			switch apiErr.Code {
			case http.StatusUnauthorized:
				return nil, 0, fmt.Errorf("%w (HTTP 401)", ErrUnauthorized)
			case http.StatusUnprocessableEntity:
				up := 0
				var parsed struct {
					Upcoming int `json:"upcoming"`
				}
				if json.Unmarshal([]byte(apiErr.Body), &parsed) == nil {
					up = parsed.Upcoming
				}
				return nil, up, ErrIdle
			}
		}
		return nil, 0, err
	}
	claim, err := payload.ParseClaim(respBody)
	if err != nil {
		return nil, 0, err
	}
	return claim, 0, nil
}

// Outlook is the count-only idle-shutdown view for this runner's trust pool
// and claimable resource class (plus classless jobs).
type Outlook struct {
	Queued  int `json:"queued"`
	Running int `json:"running"`
	Pending int `json:"pending"`
}

func (o *Outlook) HasWork() bool {
	return o != nil && o.Queued+o.Running+o.Pending > 0
}

func (c *Client) Outlook(ctx context.Context, resourceClass string) (*Outlook, error) {
	path := "/api/v1/runner/outlook"
	if resourceClass != "" {
		q := url.Values{}
		q.Set("resource_class", resourceClass)
		path += "?" + q.Encode()
	}
	body, err := c.getJSON(ctx, path)
	if err != nil {
		return nil, err
	}
	var outlook Outlook
	if err := json.Unmarshal(body, &outlook); err != nil {
		return nil, fmt.Errorf("runner outlook response: %w", err)
	}
	return &outlook, nil
}

// HeartbeatReply is the heartbeat response; Status "canceled" tells the
// runner the control plane stopped the job.
type HeartbeatReply struct {
	ID     int64  `json:"id"`
	Status string `json:"status"`
}

func (c *Client) Start(ctx context.Context, jobID int64) error {
	_, err := c.postJSON(ctx, fmt.Sprintf("/api/v1/runner/jobs/%d/start", jobID), map[string]any{})
	return err
}

func (c *Client) Heartbeat(ctx context.Context, jobID int64) (*HeartbeatReply, error) {
	body, err := c.postJSON(ctx, fmt.Sprintf("/api/v1/runner/jobs/%d/heartbeat", jobID), map[string]any{})
	if err != nil {
		return nil, err
	}
	var reply HeartbeatReply
	if err := json.Unmarshal(body, &reply); err != nil {
		// A 200 with an unexpected body is not worth failing a job over.
		return &HeartbeatReply{}, nil
	}
	return &reply, nil
}

// StepResult matches the complete contract exactly (CONTRACT.md): second-
// precision RFC3339 UTC timestamps, names per the name||type convention.
type StepResult struct {
	Name       string `json:"name"`
	ExitCode   int    `json:"exit_code"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at"`
}

func (c *Client) Complete(ctx context.Context, jobID int64, status string, stepResults []StepResult) error {
	if stepResults == nil {
		stepResults = []StepResult{}
	}
	body, err := json.Marshal(map[string]any{
		"status":       status,
		"step_results": stepResults,
	})
	if err != nil {
		return err
	}
	_, err = c.postJSONBody(ctx, fmt.Sprintf("/api/v1/runner/jobs/%d/complete", jobID), body)
	return err
}

// Release hands a claimed/running job back to the queue. A 409 (release
// limit exhausted) surfaces as *APIError for the caller to fall back to
// cancel.
func (c *Client) Release(ctx context.Context, jobID int64, reason string) error {
	_, err := c.postJSON(ctx, fmt.Sprintf("/api/v1/runner/jobs/%d/release", jobID), map[string]any{"reason": reason})
	return err
}

// PostLogChunk sends one chunk. Never retried here (the streaming layer
// owns retries and reuses the seq). Empty chunks are rejected by the server
// (422) and must never be sent.
func (c *Client) PostLogChunk(ctx context.Context, jobID int64, seq int64, chunk string) error {
	_, err := c.postJSON(ctx, fmt.Sprintf("/api/v1/jobs/%d/log_chunks", jobID),
		map[string]any{"seq": seq, "chunk": chunk})
	return err
}

// --- cache & artifacts (multipart, streamed with known length) --------------

// CacheHit is a 200 GET cache response.
type CacheHit struct {
	Key         string `json:"key"`
	Size        int64  `json:"size"`
	DownloadURL string `json:"download_url"`
}

// PutCache uploads a tarball under key (multipart, streamed — the file is
// never buffered whole in memory).
func (c *Client) PutCache(ctx context.Context, projectID int64, key, tarballPath string) (*CacheHit, error) {
	body, size, boundary, closer, err := multipartBody(
		map[string]string{"key": key},
		filePart{field: "file", filename: baseName(tarballPath), path: tarballPath, contentType: "application/gzip"},
	)
	if err != nil {
		return nil, err
	}
	defer closer.Close()
	respBody, err := c.doUpload(ctx, http.MethodPut,
		fmt.Sprintf("/api/v1/projects/%d/cache", projectID), body, size, boundary)
	if err != nil {
		return nil, err
	}
	var hit CacheHit
	if err := json.Unmarshal(respBody, &hit); err != nil && len(respBody) > 0 {
		return nil, fmt.Errorf("cache upload response: %w", err)
	}
	return &hit, nil
}

// GetCache tries the keys in order (server-side fallback). Returns nil when
// the server answers 404 (clean miss). 403 (no active job) also reads as a
// miss to cache steps — it must never fail a job.
func (c *Client) GetCache(ctx context.Context, projectID int64, keys []string) (*CacheHit, error) {
	q := url.Values{}
	for _, k := range keys {
		q.Add("keys[]", k)
	}
	respBody, err := c.getJSON(ctx, fmt.Sprintf("/api/v1/projects/%d/cache?%s", projectID, q.Encode()))
	if err != nil {
		var apiErr *APIError
		if errors.As(err, &apiErr) && (apiErr.Code == http.StatusNotFound || apiErr.Code == http.StatusForbidden) {
			return nil, nil
		}
		return nil, err
	}
	var hit CacheHit
	if err := json.Unmarshal(respBody, &hit); err != nil {
		return nil, fmt.Errorf("cache hit response: %w", err)
	}
	if hit.DownloadURL == "" {
		return nil, nil
	}
	return &hit, nil
}

// ArtifactInfo is the 201 artifact response. Destination is a pointer: the
// server sends an explicit null when unset (pinned by fixture).
type ArtifactInfo struct {
	ID          int64   `json:"id"`
	Path        string  `json:"path"`
	Destination *string `json:"destination"`
	Size        int64   `json:"size"`
	DownloadURL string  `json:"download_url"`
}

// PostArtifact uploads one file as an artifact. Empty destination is
// omitted from the form.
func (c *Client) PostArtifact(ctx context.Context, jobID int64, localPath, path, destination string) (*ArtifactInfo, error) {
	fields := map[string]string{"path": path}
	if destination != "" {
		fields["destination"] = destination
	}
	body, size, boundary, closer, err := multipartBody(fields,
		filePart{field: "file", filename: baseName(localPath), path: localPath, contentType: "application/octet-stream"})
	if err != nil {
		return nil, err
	}
	defer closer.Close()
	respBody, err := c.doUpload(ctx, http.MethodPost,
		fmt.Sprintf("/api/v1/jobs/%d/artifacts", jobID), body, size, boundary)
	if err != nil {
		return nil, err
	}
	var info ArtifactInfo
	if err := json.Unmarshal(respBody, &info); err != nil {
		return nil, fmt.Errorf("artifact response: %w", err)
	}
	return &info, nil
}

// Download fetches a (signed) URL to destPath — no Authorization header.
// The body streams to destPath+".part" and is renamed into place only after
// the transfer completed, so a killed download never leaves a half file
// behind under the final name.
func (c *Client) Download(ctx context.Context, rawURL, destPath string) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("download url: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("unsupported download scheme %q", u.Scheme)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	resp, err := c.download.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 200))
		return &APIError{Code: resp.StatusCode, Body: string(body)}
	}

	part := destPath + ".part"
	f, err := os.Create(part)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(f, resp.Body)
	closeErr := f.Close()
	if copyErr != nil {
		os.Remove(part)
		return copyErr
	}
	if closeErr != nil {
		os.Remove(part)
		return closeErr
	}
	if err := os.Rename(part, destPath); err != nil {
		os.Remove(part)
		return err
	}
	return nil
}

// --- internals ----------------------------------------------------------------

func (c *Client) postJSON(ctx context.Context, path string, payloadBody any) (json.RawMessage, error) {
	body, err := json.Marshal(payloadBody)
	if err != nil {
		return nil, err
	}
	return c.postJSONBody(ctx, path, body)
}

func (c *Client) postJSONBody(ctx context.Context, path string, body []byte) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, jsonCallTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	c.auth(req)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forge-Runner-ID", c.runnerID)
	req.Header.Set("X-Forge-Runner-Hostname", c.hostname)
	req.Header.Set("X-Forge-Runner-Implementation", "go")

	return c.do(req)
}

func (c *Client) getJSON(ctx context.Context, path string) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, jsonCallTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return nil, err
	}
	c.auth(req)
	return c.do(req)
}

// doUpload sends a prepared multipart body with an explicit Content-Length
// (the server side is proven against that). The deadline is the upload one —
// long but bounded.
func (c *Client) doUpload(ctx context.Context, method, path string, body io.Reader, size int64, boundary string) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, uploadTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, method, c.base+path, body)
	if err != nil {
		return nil, err
	}
	c.auth(req)
	req.Header.Set("Content-Type", "multipart/form-data; boundary="+boundary)
	req.ContentLength = size

	return c.do(req)
}

func (c *Client) auth(req *http.Request) {
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
}

func (c *Client) do(req *http.Request) (json.RawMessage, error) {
	resp, err := c.api.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 10<<20))
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &APIError{Code: resp.StatusCode, Body: string(body)}
	}
	if len(body) == 0 {
		return json.RawMessage(`{}`), nil
	}
	return json.RawMessage(body), nil
}

// --- multipart construction -----------------------------------------------------

type filePart struct {
	field       string
	filename    string
	path        string
	contentType string
}

type multiCloser []io.Closer

func (m multiCloser) Close() error {
	var first error
	for _, c := range m {
		if err := c.Close(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// multipartBody assembles a multipart/form-data body with a fixed boundary
// and an exact Content-Length computed from header sizes + os.Stat file
// sizes: no file content is read to size the request, and file contents
// stream from disk only when the body is consumed. Cancelling the request
// context stops reading (and so uploading) the files.
func multipartBody(fields map[string]string, files ...filePart) (io.Reader, int64, string, io.Closer, error) {
	boundary := randomBoundary()

	var segs []io.Reader
	var closers multiCloser
	total := int64(0)
	add := func(b []byte) {
		segs = append(segs, bytes.NewReader(b))
		total += int64(len(b))
	}

	// Field parts first, key order fixed so request bytes are deterministic.
	keys := make([]string, 0, len(fields))
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		add([]byte(fmt.Sprintf("--%s\r\nContent-Disposition: form-data; name=%q\r\n\r\n%s\r\n",
			boundary, k, fields[k])))
	}

	for _, f := range files {
		st, err := os.Stat(f.path)
		if err != nil {
			closers.Close()
			return nil, 0, "", nil, fmt.Errorf("multipart file %s: %w", f.path, err)
		}
		fh, err := os.Open(f.path)
		if err != nil {
			closers.Close()
			return nil, 0, "", nil, fmt.Errorf("multipart file %s: %w", f.path, err)
		}
		closers = append(closers, fh)
		add([]byte(fmt.Sprintf("--%s\r\nContent-Disposition: form-data; name=%q; filename=%q\r\nContent-Type: %s\r\n\r\n",
			boundary, f.field, f.filename, f.contentType)))
		segs = append(segs, fh)
		total += st.Size()
		add([]byte("\r\n"))
	}

	add([]byte(fmt.Sprintf("--%s--\r\n", boundary)))
	return io.MultiReader(segs...), total, boundary, closers, nil
}

func randomBoundary() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand never fails on Linux, but stay total.
		return "forgeciboundary0000000000000000000000000000"
	}
	return "forgeci" + hex.EncodeToString(b)
}

func baseName(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// JSONDeadline is the whole-request deadline used for JSON lifecycle calls,
// exported for callers issuing direct calls outside the client methods
// (e.g. the runner's final reporting after shutdown).
func JSONDeadline() time.Duration { return jsonCallTimeout }
