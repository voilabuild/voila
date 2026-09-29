// client.go implements the registry client used by `voila push`,
// `voila pull`, and the chunkstore CachedStore fetcher (via the Fetcher
// interface). It speaks the /v1 wire protocol of package registry's Server
// over stdlib net/http, with retries limited to a single, opt-in attempt
// (v0.2 is trusted-network; no exotic backoff yet).
package registry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"
)

// defaultMaxIdleConnsPerHost is the per-host idle-connection pool size used by
// the client's Transport. It is sized to comfortably exceed the push upload
// fan-out (default 64) so every push worker can reuse a kept-alive connection
// instead of re-dialing (and re-TLS-handshaking on HTTPS) on every chunk PUT.
// The stdlib default of 2 is a severe bottleneck under concurrent push.
const defaultMaxIdleConnsPerHost = 256

// Client is the HTTP registry client. The base URL is the registry root
// (e.g. "http://localhost:7423"); the client appends /v1/... paths. It is safe
// for concurrent use (the underlying *http.Client has its own goroutine
// safety and a connection pool).
type Client struct {
	base    string // normalized, no trailing slash
	httpc   *http.Client
	timeout time.Duration

	// token is an optional bearer API key sent as `Authorization: Bearer
	// <token>` on every request. Empty means no auth header is sent (the
	// trusted-network default). Configured via WithToken (e.g. from
	// $VOILA_REGISTRY_TOKEN).
	token string

	// chunkEndpoint is the optional origin (e.g. S3/R2/CDN base URL) this
	// registry advertises for chunk bytes, discovered lazily via a single
	// GET /v1/registry/config. When non-empty, GetChunk fetches <id> from
	// <chunk_endpoint>/<id> instead of /v1/chunks/<id>. HasChunk (HEAD),
	// MissingChunks, and PUT always use the registry itself.
	chunkEndpoint string
	originOnce    sync.Once
	originErr     error // captured for diagnostics; does not block fallback
}

// Option configures a Client at construction (see WithToken).
type Option func(*Client)

// WithToken sets the bearer API key the client sends as `Authorization:
// Bearer <token>` on every request. Empty (the default) sends no auth header.
// Used to authenticate against registries that require an API key (e.g. the
// voila-registry web/cloud backend), typically sourced from
// $VOILA_REGISTRY_TOKEN.
func WithToken(token string) Option {
	return func(c *Client) { c.token = token }
}

// NewClient returns a Client bound to base URL. A trailing "/" on base is
// trimmed. The default HTTP timeout is 60s; pass WithTimeout to override.
// Options may configure auth (WithToken) and future behaviors.
//
// The client uses a tuned *http.Transport (not the http.DefaultTransport):
// MaxIdleConnsPerHost is raised to defaultMaxIdleConnsPerHost so a 64-way
// push fan-out reuses connections instead of re-dialing per request, and
// ForceAttemptHTTP2 is enabled so an https:// registry (e.g. a Railway app
// behind its TLS edge) negotiates HTTP/2 — letting the 64 PUTs multiplex on a
// single TCP+TLS connection instead of opening 64. A blanket Client.Timeout
// is intentionally NOT set (it would kill slow-but-progressing body uploads
// on a WAN); per-request deadlines are the caller's responsibility via
// context.
func NewClient(base string, opts ...Option) (*Client, error) {
	if base == "" {
		return nil, errors.New("registry: empty base URL")
	}
	u, err := url.Parse(base)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("registry: invalid base URL %q", base)
	}
	tr := newTransport()
	c := &Client{
		base:    strings.TrimRight(u.String(), "/"),
		httpc:   &http.Client{Transport: tr},
		timeout: 60 * time.Second,
	}
	for _, opt := range opts {
		if opt != nil {
			opt(c)
		}
	}
	return c, nil
}

// newTransport returns a tuned *http.Transport for the registry client. It is
// a fresh instance per Client so Close (CloseIdleConnections) does not race
// with other clients; the settings are the tuned defaults documented above
// NewClient.
func newTransport() *http.Transport {
	return &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          defaultMaxIdleConnsPerHost,
		MaxIdleConnsPerHost:   defaultMaxIdleConnsPerHost,
		MaxConnsPerHost:       0, // unbounded; the push fan-out bounds in-flight
		IdleConnTimeout:       90 * time.Second,
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: 60 * time.Second,
	}
}

// WithTimeout returns a Client identical to c except for a new per-request
// timeout, reusing the tuned Transport so connection-pooling is preserved.
// The returned client is a fresh instance that re-discovers the chunk origin
// on its first GetChunk (a timeout-tuned client is an independent client).
func (c *Client) WithTimeout(d time.Duration) *Client {
	return &Client{
		base:    c.base,
		httpc:   &http.Client{Transport: c.httpc.Transport, Timeout: d},
		timeout: d,
		token:   c.token,
	}
}

// authHeader sets the Authorization header on req when the client has a bearer
// token configured. It is a no-op when no token is set (the trusted-network
// default). Every outbound request goes through this so auth applies uniformly
// across chunk, image, missing, and discovery endpoints.
func (c *Client) authHeader(req *http.Request) {
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
}

// HTTPClient returns the underlying *http.Client (for advanced callers that
// want to share a transport, e.g. tests).
func (c *Client) HTTPClient() *http.Client { return c.httpc }

// Base returns the base URL the client was constructed with.
func (c *Client) Base() string { return c.base }

// Close releases any per-client transport resources. It is safe to call
// multiple times; the underlying idle connections are reaped on Close.
func (c *Client) Close() {
	if c.httpc != nil {
		c.httpc.CloseIdleConnections()
	}
}

// ChunkOrigin returns the discovered chunk-serving origin (base URL), or "" if
// the registry has not advertised one (chunks are served by the registry itself
// at /v1/chunks/<id>). The origin is fetched lazily on the first GetChunk (or on
// the first call to this method); before then it may be "". It is read-only —
// operators configure the origin via the voila-registry -chunk-origin flag.
func (c *Client) ChunkOrigin() string {
	c.ensureOrigin(context.Background())
	return c.chunkEndpoint
}

// ensureOrigin fetches GET /v1/registry/config exactly once and caches the
// result. It is safe to call concurrently. Failure is non-fatal: on an older
// registry (404), a bad JSON body, or a network error, chunkEndpoint stays ""
// and GetChunk falls back to /v1/chunks/<id> exactly as today — an
// unreachable origin is treated the same as "no origin advertised".
func (c *Client) ensureOrigin(ctx context.Context) {
	c.originOnce.Do(func() {
		origin, err := c.fetchOrigin(ctx)
		c.chunkEndpoint = origin
		c.originErr = err
		switch {
		case err != nil:
			// Discovery genuinely failed (network/decode/non-200 that carried
			// a body we didn't expect, etc.) — not a clean "no origin".
			// Surface it once so it isn't invisible; GetChunk still falls
			// back to /v1/chunks/<id> below.
			log.Printf("registry: chunk origin discovery failed (%v); chunks served from registry", err)
		case origin != "":
			// Origin declared: chunk reads will go to <origin>/<id> directly.
			log.Printf("registry: chunk origin %q (chunks served directly from origin)", origin)
		}
	})
}

// fetchOrigin queries GET /v1/registry/config and returns the declared
// chunk_endpoint ("" if the registry does not advertise one).
func (c *Client) fetchOrigin(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/v1/registry/config", nil)
	if err != nil {
		return "", err
	}
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Drain so the connection can be reused.
		_, _ = io.Copy(io.Discard, resp.Body)
		// 404 on /v1/registry/config is the normal "registry without this
		// endpoint" case (an older registry): fall back silently. Any other
		// non-200 is reported as an error so the once-diag logs a warning.
		if resp.StatusCode != http.StatusNotFound {
			return "", fmt.Errorf("registry: GET /v1/registry/config: %s", resp.Status)
		}
		return "", nil
	}
	var cfg struct {
		ChunkEndpoint string `json:"chunk_endpoint"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		return "", err
	}
	return strings.TrimRight(cfg.ChunkEndpoint, "/"), nil
}

// GetChunk fetches the raw (uncompressed) bytes for id, returning an error
// that wraps chunkstore.ErrNotFound when the registry reports 404 so the
// CachedStore's miss path works uniformly. It implements chunkstore.Fetcher.
//
// If the registry advertised a chunk origin (S3/R2/CDN), the bytes come from
// <chunk_endpoint>/<id> directly instead of /v1/chunks/<id>. HEAD/PUT/Missing
// Chunks are unaffected — only this read path reroutes, per the "chunks can
// live on another server" contract.
func (c *Client) GetChunk(ctx context.Context, id chunkstore.ChunkID) ([]byte, error) {
	// Discover the origin on the first call (best-effort, one-shot). On an
	// older/unreachable registry this is a silent no-op (chunkEndpoint == "")
	// and we fall back to the registry below.
	c.ensureOrigin(ctx)

	u := c.base + "/v1/chunks/" + id.String()
	if c.chunkEndpoint != "" {
		u = c.chunkEndpoint + "/" + id.String()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	// Chunk reads are intentionally unauthenticated: chunk bytes are
	// content-addressed (id = BLAKE3 of the bytes) and immutable, the
	// registry's chunk GET endpoint is public by protocol (no auth check),
	// and — importantly — sending no Authorization header lets a CDN/edge
	// in front of the registry cache the response (the
	// `Cache-Control: public, max-age=31536000, immutable` header opts it
	// in). An Authorization header would bifurcate or disable edge caching
	// (the cache key would vary by token, or the edge would refuse to
	// cache an authenticated response), defeating the CDN for the hot read
	// path. Existence negotiation (HEAD/missing) and writes (PUT) keep auth.
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		// Transport decompression of the response body: a registry that
		// serves chunks with Content-Encoding: zstd (the cloud registry
		// stores + serves compressed bytes) sends the zstd form on the
		// wire. The id is the BLAKE3 of the RAW bytes, so decompress before
		// returning — CachedStore verifies BLAKE3(raw) == id and writes
		// the raw bytes through to the local cache. No header / "identity"
		// ⇒ the body is already raw (the bundled in-process registry), and
		// we return it as-is.
		if enc := resp.Header.Get("Content-Encoding"); strings.EqualFold(enc, "zstd") {
			raw, derr := chunkstore.DecodeStored(data, chunkstore.AlgoZstd)
			if derr != nil {
				return nil, fmt.Errorf("registry: decode chunk %s: %w", id, derr)
			}
			data = raw
		}
		return data, nil
	case http.StatusNotFound:
		return nil, fmt.Errorf("%w: chunk %s", chunkstore.ErrNotFound, id)
	default:
		return nil, fmt.Errorf("registry: GET chunk %s: %s", id, resp.Status)
	}
}

// HasChunk reports whether the registry holds id. It uses HEAD so the bytes
// are not transferred. Implements chunkstore.Fetcher-style probing but is
// not part of the Fetcher interface (Fetcher covers only GetChunk); push
// uses HasChunk to skip re-uploading existing chunks.
func (c *Client) HasChunk(ctx context.Context, id chunkstore.ChunkID) (bool, error) {
	url := c.base + "/v1/chunks/" + id.String()
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return false, err
	}
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound:
		return false, nil
	default:
		return false, fmt.Errorf("registry: HEAD chunk %s: %s", id, resp.Status)
	}
}

// PutChunk uploads body to /v1/chunks/<id>. The server verifies BLAKE3
// (body) == id; a mismatch surfaces as a 400 error. Put is idempotent from
// the caller's perspective: a 200 (already existed) is not an error.
//
// The wire format is zstd: putChunk compresses body to zstd and sends
// Content-Encoding: zstd (see putChunk). The server decompresses before its
// BLAKE3-against-id verification, so the id (hash of the RAW content) still
// verifies. Callers that already hold the stored zstd form should use
// PutChunkStored to avoid re-compressing.
func (c *Client) PutChunk(ctx context.Context, id chunkstore.ChunkID, body []byte) error {
	return c.putChunk(ctx, id, body, "")
}

// PutChunkStored uploads the stored (possibly compressed) bytes for id. When
// algo is AlgoZstd the bytes are sent as-is with Content-Encoding: zstd (no
// re-compression). When algo is AlgoRaw the bytes are compressed to zstd for
// the wire (the registry requires Content-Encoding: zstd on PUT). The server
// decompresses before its BLAKE3-against-id verification, so the id remains
// the hash of the RAW content — the wire form is purely a transport concern.
func (c *Client) PutChunkStored(ctx context.Context, id chunkstore.ChunkID, stored []byte, algo int) error {
	return c.putChunk(ctx, id, stored, chunkstore.AlgoName(algo))
}

// putChunk is the single PUT implementation shared by PutChunk and
// PutChunkStored. encoding is the Content-Encoding the caller believes the
// body already carries ("" for raw, "zstd" for an already-zstd body). The
// wire format is always zstd: if the body is not already zstd, it is
// compressed here before sending, and Content-Encoding: zstd is always set.
// The server requires zstd on PUT and decompresses before BLAKE3 verification.
func (c *Client) putChunk(ctx context.Context, id chunkstore.ChunkID, body []byte, encoding string) error {
	if !strings.EqualFold(encoding, "zstd") {
		compressed, cerr := chunkstore.EncodeZstd(body)
		if cerr != nil {
			return fmt.Errorf("registry: compress chunk %s: %w", id, cerr)
		}
		body = compressed
		encoding = "zstd"
	}
	url := c.base + "/v1/chunks/" + id.String()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Content-Length", strconv.Itoa(len(body)))
	req.Header.Set("Content-Encoding", encoding)
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	switch resp.StatusCode {
	case http.StatusOK, http.StatusCreated:
		return nil
	case http.StatusBadRequest:
		return fmt.Errorf("registry: PUT chunk %s: hash mismatch (400)", id)
	default:
		return fmt.Errorf("registry: PUT chunk %s: %s", id, resp.Status)
	}
}

// Manifest fetch failures surfaced by GetImage / GetImageManifest. They exist
// so callers can tell "no such image" from "bad credentials" via errors.Is
// instead of parsing strings, while the *ManifestError carries the human
// message the CLI prints.
var (
	// ErrImageNotFound: the registry answered 404 for the ref. Note that
	// registries deliberately return 404 (not 403) for PRIVATE images when
	// the caller lacks access, so this sentinel means "not found OR not
	// visible to you" — it must not be read as proof the image exists.
	ErrImageNotFound = errors.New("image not found")

	// ErrNotAuthorized: the registry explicitly answered 401 or 403 — the
	// token is missing, wrong, or not permitted for this ref.
	ErrNotAuthorized = errors.New("not authorized")
)

// ManifestError is the error type returned by manifest-level registry calls
// (GetImage / GetImageManifest). It renders an actionable top-line message
// ("image X not found on Y", "not authorized for image X ...") while keeping
// the underlying cause reachable via errors.Is (ErrImageNotFound,
// ErrNotAuthorized) and errors.As (*ManifestError).
type ManifestError struct {
	Ref  string // requested image ref
	Base string // registry base URL the request went to
	Err  error  // ErrImageNotFound, ErrNotAuthorized, or the transport error
}

// Error implements error with a human-first message. The 404 wording hedges
// because private manifests are served as 404 to non-owners (see
// doc/INSTALL.md) — a bare 404 cannot distinguish "typo" from "private".
func (e *ManifestError) Error() string {
	switch {
	case errors.Is(e.Err, ErrNotAuthorized):
		return fmt.Sprintf("not authorized for image %q on %s (check VOILA_REGISTRY_TOKEN)", e.Ref, e.Base)
	case errors.Is(e.Err, ErrImageNotFound):
		return fmt.Sprintf("image %q not found on %s (ref may be wrong, or the image is private)", e.Ref, e.Base)
	default:
		return fmt.Sprintf("fetching image %q from %s: %v", e.Ref, e.Base, e.Err)
	}
}

// Unwrap exposes the sentinel / transport cause for errors.Is and errors.As.
func (e *ManifestError) Unwrap() error { return e.Err }

// GetImage fetches the JSON ImageManifest bytes for ref. ref is
// url.QueryEscaped onto the path by the client.
//
// Registry-level failures return a *ManifestError wrapping ErrImageNotFound
// (404), ErrNotAuthorized (401/403), or the transport error, so the CLI can
// print an actionable message instead of leaking store-layer internals. Note
// the chunk GET path (GetChunk) intentionally keeps its chunkstore.ErrNotFound
// mapping — that contract belongs to the CachedStore miss path, not manifests.
func (c *Client) GetImage(ctx context.Context, ref string) ([]byte, error) {
	url := c.base + "/v1/images/" + url.QueryEscape(ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, &ManifestError{Ref: ref, Base: c.base, Err: err}
	}
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, &ManifestError{Ref: ref, Base: c.base, Err: err}
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		data, rerr := io.ReadAll(resp.Body)
		if rerr != nil {
			return nil, &ManifestError{Ref: ref, Base: c.base, Err: rerr}
		}
		return data, nil
	case http.StatusNotFound:
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, &ManifestError{Ref: ref, Base: c.base, Err: ErrImageNotFound}
	case http.StatusUnauthorized, http.StatusForbidden:
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, &ManifestError{Ref: ref, Base: c.base, Err: ErrNotAuthorized}
	default:
		return nil, fmt.Errorf("registry: GET image %q: %s", ref, resp.Status)
	}
}

// GetImageManifest is a convenience wrapper that GETs the JSON manifest and
// converts it into a *voilapb.ImageManifest (the internal representation used
// by the worker, imagestore, and CLI).
func (c *Client) GetImageManifest(ctx context.Context, ref string) (*voilapb.ImageManifest, error) {
	data, err := c.GetImage(ctx, ref)
	if err != nil {
		return nil, err
	}
	var m manifestJSON
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("registry: unmarshal image %q: %w", ref, err)
	}
	im, err := manifestFromJSON(&m)
	if err != nil {
		return nil, fmt.Errorf("registry: decode image %q: %w", ref, err)
	}
	return im, nil
}

// PutImage uploads raw JSON ImageManifest bytes for ref. The server validates
// the JSON before persisting; a 400 surfaces as an error.
func (c *Client) PutImage(ctx context.Context, ref string, body []byte) error {
	url := c.base + "/v1/images/" + url.QueryEscape(ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Length", strconv.Itoa(len(body)))
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	switch resp.StatusCode {
	case http.StatusCreated, http.StatusOK:
		return nil
	case http.StatusBadRequest:
		return fmt.Errorf("registry: PUT image %q: bad manifest (400)", ref)
	case http.StatusUnauthorized, http.StatusForbidden:
		return fmt.Errorf("not authorized to push image %q to %s (check VOILA_REGISTRY_TOKEN): %w",
			ref, c.base, ErrNotAuthorized)
	default:
		return fmt.Errorf("registry: PUT image %q: %s", ref, resp.Status)
	}
}

// PutImageManifest converts im to its JSON wire form and uploads it for ref.
func (c *Client) PutImageManifest(ctx context.Context, ref string, im *voilapb.ImageManifest) error {
	data, err := json.Marshal(manifestToJSON(im))
	if err != nil {
		return fmt.Errorf("registry: marshal image %q: %w", ref, err)
	}
	return c.PutImage(ctx, ref, data)
}

// missingBatchSize is the per-POST id cap on POST /v1/chunks/missing. 16384 is
// chosen to keep request bodies well under the server's 8 MiB limit (a full
// batch is ~1 MiB of hex) while amortizing request overhead across thousands
// of ids in a single round trip. MissingChunks batches internally at this
// size so a 25k-chunk push negotiates in two requests rather than 25k HEADs.
const missingBatchSize = 16384

// MissingChunks returns the subset of ids the server does NOT hold. It uses
// POST /v1/chunks/missing, batching at missingBatchSize ids per request so a
// one-file image delta negotiates in a couple of round trips even with the
// server's per-request id cap. Order of the returned ids is unspecified.
//
// If the server responds 404 on /v1/chunks/missing (an older registry that
// predates the bulk-stat endpoint), MissingChunks returns
// ErrBulkMissingUnsupported so callers can fall back to per-chunk HEADs.
func (c *Client) MissingChunks(ctx context.Context, ids []chunkstore.ChunkID) ([]chunkstore.ChunkID, error) {
	var out []chunkstore.ChunkID
	for i := 0; i < len(ids); i += missingBatchSize {
		end := i + missingBatchSize
		if end > len(ids) {
			end = len(ids)
		}
		batch, err := c.missingChunksBatch(ctx, ids[i:end])
		if err != nil {
			return nil, err
		}
		out = append(out, batch...)
	}
	return out, nil
}

// missingChunksBatch is the single-request primitive: POST one batch of ids
// and return the subset the server is missing.
func (c *Client) missingChunksBatch(ctx context.Context, ids []chunkstore.ChunkID) ([]chunkstore.ChunkID, error) {
	idStrs := make([]string, len(ids))
	for i, id := range ids {
		idStrs[i] = id.String()
	}
	reqBody, err := json.Marshal(struct {
		IDs []string `json:"ids"`
	}{IDs: idStrs})
	if err != nil {
		return nil, err
	}
	url := c.base + "/v1/chunks/missing"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Length", strconv.Itoa(len(reqBody)))
	c.authHeader(req)
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}
		var respData struct {
			Missing []string `json:"missing"`
		}
		if err := json.Unmarshal(body, &respData); err != nil {
			return nil, fmt.Errorf("registry: bad missing response: %w", err)
		}
		missing := make([]chunkstore.ChunkID, 0, len(respData.Missing))
		for _, s := range respData.Missing {
			id, perr := chunkstore.ParseChunkID(s)
			if perr != nil {
				return nil, fmt.Errorf("registry: bad chunk id in missing response: %q", s)
			}
			missing = append(missing, id)
		}
		return missing, nil
	case http.StatusNotFound:
		// Older registry: the /v1/chunks/missing route is absent. Drain so
		// the connection can be reused by the fallback HEADs.
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, ErrBulkMissingUnsupported
	case http.StatusBadRequest:
		// Surface the error message so the caller can see why the request
		// was rejected (malformed id, too many, etc.).
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return nil, fmt.Errorf("registry: POST /v1/chunks/missing: %s: %s",
			resp.Status, strings.TrimSpace(string(msg)))
	default:
		return nil, fmt.Errorf("registry: POST /v1/chunks/missing: %s", resp.Status)
	}
}
