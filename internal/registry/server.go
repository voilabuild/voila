// Package registry implements the HTTP chunk + image-manifest registry used
// by `voila-registry` (server side) and `voila push` / `voila pull` / the
// CachedStore fetcher (client side). The wire protocol is documented in the
// OpenAPI 3.1 spec at openapi.yaml (served at GET /openapi.yaml); everything
// is under /v1 and uses stdlib net/http only.
//
// The registry is a thin facade over a chunkstore.ChunkStore plus a flat
// <imageDir>/<sha256(ref) hex>.json file tree for JSON ImageManifest blobs.
// No auth is implemented (local / trusted-network usage; documented).
package registry

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"voila/internal/chunkstore"

	"lukechampine.com/blake3"
)

// openapiYAML is the canonical OpenAPI 3.1 spec for the registry's /v1 wire
// protocol. It is embedded so any running registry self-documents at
// GET /openapi.yaml — the served spec is always the one matching the binary.
//
//go:embed openapi.yaml
var openapiYAML []byte

// maxChunkBody is the upper bound on a chunk PUT body. Chunks are ≤1 MiB;
// anything larger is rejected before reading the body (cheap DoS guard and a
// correctness fence: a sender that tries to push a 1 GiB blob is told no
// before 1 GiB of bandwidth is spent).
const maxChunkBody = 8 << 20 // 8 MiB

// maxImageBody bounds image-manifest PUTs. Manifests are KB-scale; 4 MiB is
// generous yet bounded.
const maxImageBody = 4 << 20

// maxMissingBody bounds a POST /v1/chunks/missing request. 8 MiB holds
// >550k newline-separated 64-hex ids, far past the id cap below; the cap is a
// cheap DoS guard and a correctness fence (a client that ships a GiB blob is
// told no before spending the bandwidth).
const maxMissingBody = 8 << 20

// maxMissingIDs is the per-request id cap on POST /v1/chunks/missing. 65536
// is the documented wire limit; going over returns 400 (per spec).
const maxMissingIDs = 65536

// ErrBulkMissingUnsupported is returned by (*Client).MissingChunks when the
// registry answers 404 on POST /v1/chunks/missing, i.e. it predates the
// bulk-stat endpoint. Callers (cmd_push) fall back to per-chunk HEADs.
var ErrBulkMissingUnsupported = errors.New("registry: bulk missing-chunks endpoint not supported")

// Server is the v0.2 HTTP chunk + image-manifest registry. It is safe for
// concurrent use; the underlying chunkstore.ChunkStore must itself be safe
// (LocalStore is). The image directory is created on construction.
type Server struct {
	store       chunkstore.ChunkStore
	imageDir    string
	chunkOrigin string // optional public base URL chunks are served from (S3/R2/CDN)
	log         *log.Logger
}

// ServerOption configures a Server at construction (see WithChunkOrigin).
type ServerOption func(*Server)

// WithChunkOrigin sets the public base URL that this registry advertises as the
// origin for chunk bytes (via GET /v1/registry/config). When set, clients fetch
// a chunk <id> (64-hex) from <chunk_origin>/<id> (e.g. an S3/R2/CDN origin)
// instead of /v1/chunks/<id>. Empty (the default) leaves chunk fetches on the
// registry itself. The trailing slash is trimmed so the id joins cleanly.
//
// This only declares WHERE chunks are served from — the registry still stores
// and serves chunks on /v1/chunks/<id> unless an object-store-backed ChunkStore
// (a separate task) backs it. HasChunk (HEAD), MissingChunks, and PUT are
// unaffected: existence negotiation and writes stay on the registry.
func WithChunkOrigin(origin string) ServerOption {
	return func(s *Server) { s.setChunkOrigin(origin) }
}

func (s *Server) setChunkOrigin(origin string) {
	s.chunkOrigin = strings.TrimRight(origin, "/")
}

// NewServer returns a Server backed by store and imageDir, creating imageDir
// if necessary. Options may configure the chunk origin (and future behaviors).
// The signature is variadic so existing two-argument callers (tests, the local
// backend) compile and behave unchanged.
func NewServer(store chunkstore.ChunkStore, imageDir string, opts ...ServerOption) (*Server, error) {
	if store == nil {
		return nil, errors.New("registry: nil chunk store")
	}
	if imageDir == "" {
		return nil, errors.New("registry: empty image dir")
	}
	if err := os.MkdirAll(imageDir, 0o755); err != nil {
		return nil, fmt.Errorf("registry: mkdir image dir: %w", err)
	}
	srv := &Server{
		store:    store,
		imageDir: imageDir,
		log:      log.Default(),
	}
	for _, opt := range opts {
		if opt != nil {
			opt(srv)
		}
	}
	return srv, nil
}

// SetLogger overrides the default logger (used by tests to capture or sink
// the access log; production writes to os.Stdout).
func (s *Server) SetLogger(l *log.Logger) {
	if l != nil {
		s.log = l
	}
}

// Handler returns the http.Handler serving the /v1 wire protocol. Routes:
//
//	GET    /openapi.yaml            → 200 the OpenAPI 3.1 spec (self-document)
//	GET    /v1/chunks/<64-hex>      → 200 raw bytes | 404
//	HEAD   /v1/chunks/<64-hex>      → 200 | 404
//	PUT    /v1/chunks/<64-hex>      → 201 (or 200 if it already existed);
//	                                   body BLAKE3 must equal <64-hex> (400 on
//	                                   mismatch); max body 8 MiB.
//	POST   /v1/chunks/missing       → 200 JSON {"missing":[...]} subset the
//	                                   server does NOT have (empty array = all);
//	                                   request is JSON {"ids":[...]}; max body
//	                                   8 MiB, max 65536 ids (400 over);
//	                                   malformed id → 400 naming the index.
//	GET    /v1/registry/config      → 200 JSON {"chunk_endpoint":"..."} (registry
//	                                   config: optional chunk-serving origin)
//	GET    /v1/images/<url-ref>     → 200 JSON ImageManifest | 404
//	PUT    /v1/images/<url-ref>     → 201 after JSON validation
//	anything else                   → 404
//
// A small logging middleware wraps method, path, status, byte count, and
// duration to stdout.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/openapi.yaml", s.handleOpenAPI)
	mux.HandleFunc("/v1/chunks/missing", s.handleMissingChunks)
	mux.HandleFunc("/v1/chunks/", s.handleChunk)
	mux.HandleFunc("/v1/registry/config", s.handleRegistryConfig)
	mux.HandleFunc("/v1/images/", s.handleImage)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	})
	return s.logging(mux)
}

// Serve constructs an *http.Server and serves on lis until the listener is
// closed. Convenience wrapper for callers that want the registry to own the
// http.Server (e.g. `voila registry`).
func (s *Server) Serve(lis net.Listener) error {
	srv := &http.Server{Handler: s.Handler()}
	return srv.Serve(lis)
}

// ServeTLS constructs an *http.Server and serves HTTPS (and, automatically,
// HTTP/2) on lis until the listener is closed. The stdlib http.Server enables
// HTTP/2 by default when ServeTLS is called with a non-nil cert/key pair, so
// a 64-way push fan-out multiplexes on a single TCP+TLS connection instead of
// opening 64. Convenience wrapper for callers that want the registry to own
// the http.Server (e.g. `voila registry -tls-cert ... -tls-key ...`).
func (s *Server) ServeTLS(lis net.Listener, certFile, keyFile string) error {
	srv := &http.Server{Handler: s.Handler()}
	return srv.ServeTLS(lis, certFile, keyFile)
}

// handleHealthz is a cheap liveness/readiness probe for load balancers and
// PaaS health checks (e.g. Railway). It exercises nothing beyond the handler
// goroutine itself; the registry has no external dependency that can be down.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// handleOpenAPI serves the embedded OpenAPI 3.1 spec at GET /openapi.yaml so
// any running registry self-documents its wire protocol. The spec is embedded
// at build time, so the served document always matches the binary's behaviour.
func (s *Server) handleOpenAPI(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/yaml; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(openapiYAML)
}

// writeJSONError emits a JSON error envelope {"error":"..."} with the given
// status. Used by the JSON-speaking endpoints (/v1/chunks/missing and
// /v1/images/) so their errors share the same content type as their success
// responses. Chunk endpoints keep plain-text http.Error (their bodies are
// binary, not JSON).
func writeJSONError(w http.ResponseWriter, msg string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// logging is the access-log middleware: method, path, status, byte count,
// duration → stdout (via s.log).
func (s *Server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &countingResponseWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		s.log.Printf("%s %s %d %dB %s",
			r.Method, r.URL.Path, rw.status, rw.bytes, time.Since(start).Round(time.Millisecond))
	})
}

// --- chunks ---

// handleChunk routes GET/HEAD/PUT on a chunk id path.
func (s *Server) handleChunk(w http.ResponseWriter, r *http.Request) {
	// Path: /v1/chunks/<hex>
	p := strings.TrimPrefix(r.URL.Path, "/v1/chunks/")
	if !validChunkPath(p) {
		http.NotFound(w, r)
		return
	}
	id, err := chunkstore.ParseChunkID(p)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.getChunk(w, r, id)
	case http.MethodHead:
		s.headChunk(w, r, id)
	case http.MethodPut:
		s.putChunk(w, r, id)
	default:
		w.Header().Set("Allow", "GET, HEAD, PUT")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) getChunk(w http.ResponseWriter, r *http.Request, id chunkstore.ChunkID) {
	ctx := r.Context()
	data, err := s.store.Get(ctx, id)
	if err != nil {
		if errors.Is(err, chunkstore.ErrNotFound) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	// Chunks are content-addressed (id = BLAKE3 of the raw bytes) and
	// immutable: the same id always returns the same bytes, forever. A CDN
	// in front of the registry may therefore cache /v1/chunks/<id> responses
	// indefinitely without revalidation — this header opts that response in
	// for edge caching (the read hot path; PUTs are not cacheable and bypass
	// the edge to origin). "immutable" also tells clients the object will
	// never change, so they need not revalidate on a cache hit.
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodGet {
		_, _ = w.Write(data)
	}
}

func (s *Server) headChunk(w http.ResponseWriter, r *http.Request, id chunkstore.ChunkID) {
	// Stat never fetches content (interface contract); a HEAD over GET keeps
	// the request off the (potentially network-bound for CachedStore) read
	// path entirely.
	if _, ok := s.store.Stat(id); !ok {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	// Match getChunk's cacheability so a CDN HEAD probe (e.g. a cache fill or
	// revalidation check) sees the same policy as the GET it represents.
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	w.WriteHeader(http.StatusOK)
}

func (s *Server) putChunk(w http.ResponseWriter, r *http.Request, id chunkstore.ChunkID) {
	// Cheap size cap before reading the body. The cap is on the WIRE form:
	// a zstd-compressed body is smaller than the raw chunk, so a compressed
	// PUT of a near-1 MiB chunk still fits well under the 8 MiB cap.
	if r.ContentLength > maxChunkBody {
		http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxChunkBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		// MaxBytesReader returns *http.MaxBytesError on overflow; both that
		// and a truncated read surface as 413 with a small explanatory body.
		http.Error(w, "read body: "+err.Error(), http.StatusRequestEntityTooLarge)
		return
	}
	// Transport decompression: a PUT may carry the stored (zstd-compressed)
	// form with Content-Encoding: zstd to avoid re-expanding compressed
	// chunks for the wire. The id is the BLAKE3 of the RAW content, so we
	// decompress BEFORE the hash check. An unknown encoding (or a decode
	// failure) is a 400 — the client must use a supported encoding.
	algo := chunkstore.AlgoFromName(r.Header.Get("Content-Encoding"))
	raw := body
	if algo != chunkstore.AlgoRaw {
		decoded, derr := chunkstore.DecodeStored(body, algo)
		if derr != nil {
			http.Error(w, "decode Content-Encoding: "+derr.Error(), http.StatusBadRequest)
			return
		}
		raw = decoded
	}
	got := chunkHash(raw)
	if got != id {
		http.Error(w, "chunk id mismatch: body BLAKE3 does not match path id",
			http.StatusBadRequest)
		return
	}
	// 201 if newly stored, 200 if it pre-existed — the existence check must
	// precede the (idempotent) Put or it would always report 200. A parallel
	// PUT may race us; either way the chunk ends up present, which is all
	// the contract promises.
	_, existed := s.store.Stat(id)
	if _, err := s.store.Put(raw); err != nil {
		http.Error(w, "store: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if existed {
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusCreated)
	}
}

// handleMissingChunks answers POST /v1/chunks/missing: a JSON request body
// {"ids":["<64hex>",…]} and a JSON response {"missing":[…]} listing the
// subset the server does NOT have (empty array = has them all). The server
// answers via store.Stat only — it never fetches bytes — so the endpoint is
// cheap even when the store is backed by the network (CachedStore's Stat
// contract: no fetch).
//
// Limits (per spec): max 8 MiB body, max 65536 ids; either over → 400. A
// malformed id anywhere → 400 naming the index (0-indexed). An empty body
// or {"ids":[]} is a legal request meaning "you sent me nothing".
//
// Method other than POST → 405. The route is registered ahead of
// /v1/chunks/<hex> so ServeMux matches it as the more specific pattern.
func (s *Server) handleMissingChunks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeJSONError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if r.ContentLength > maxMissingBody {
		writeJSONError(w, fmt.Sprintf("body too large (max %d bytes)", maxMissingBody), http.StatusBadRequest)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMissingBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSONError(w, "read body: "+err.Error(), http.StatusBadRequest)
		return
	}
	var req struct {
		IDs []string `json:"ids"`
	}
	if len(body) > 0 {
		if err := json.Unmarshal(body, &req); err != nil {
			writeJSONError(w, "invalid request: "+err.Error(), http.StatusBadRequest)
			return
		}
	}
	if len(req.IDs) > maxMissingIDs {
		writeJSONError(w, fmt.Sprintf("too many ids (max %d)", maxMissingIDs), http.StatusBadRequest)
		return
	}
	missing := make([]string, 0, len(req.IDs))
	for i, idStr := range req.IDs {
		id, perr := chunkstore.ParseChunkID(idStr)
		if perr != nil {
			writeJSONError(w, fmt.Sprintf("malformed chunk id at index %d: %q", i, idStr), http.StatusBadRequest)
			return
		}
		if _, ok := s.store.Stat(id); !ok {
			missing = append(missing, idStr)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(struct {
		Missing []string `json:"missing"`
	}{Missing: missing})
}

// --- registry config ---

// handleRegistryConfig answers GET /v1/registry/config: the registry's
// self-describing config. Currently the only field is "chunk_endpoint" — the
// optional public base URL chunks are served from (e.g. an S3/R2/CDN origin).
//
// When non-empty, clients fetch chunk <id> (64-hex) from
// <chunk_endpoint>/<id> — bytes come directly from that origin instead of the
// registry's /v1/chunks/<id>. When empty, clients use /v1/chunks/<id> (the
// local/default behavior). Objects are content-addressed and immutable, so the
// same long-cache story applies to the external origin (it must serve the raw
// chunk bytes whose BLAKE3 equals the id).
//
// The response is Cache-Control: no-store: the origin is mutable (an operator
// can repoint chunks to a new bucket), unlike the immutable chunk bytes.
func (s *Server) handleRegistryConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", "GET")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{"chunk_endpoint": s.chunkOrigin})
}

// --- images ---

// handleImage routes GET/PUT on an image ref path.
func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimPrefix(r.URL.Path, "/v1/images/")
	if p == "" {
		http.NotFound(w, r)
		return
	}
	// The ref arrives url-path-escaped. We use RawPath when present so refs
	// containing '/' (escaped as %2F) survive server-side as part of the ref
	// rather than being split into path elements.
	if r.URL.RawPath != "" {
		p = strings.TrimPrefix(r.URL.RawPath, "/v1/images/")
	}
	ref := p
	if dec, err := url.QueryUnescape(p); err == nil && dec != "" {
		ref = dec
	}
	if !validRef(ref) {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodGet:
		s.getImage(w, r, ref)
	case http.MethodPut:
		s.putImage(w, r, ref)
	default:
		w.Header().Set("Allow", "GET, PUT")
		writeJSONError(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) getImage(w http.ResponseWriter, r *http.Request, ref string) {
	path := s.imagePath(ref)
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			writeJSONError(w, "image not found", http.StatusNotFound)
			return
		}
		writeJSONError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	// A ref is NOT immutable: `voila push` may overwrite an existing ref's
	// manifest (the server's putImage replaces the stored file). Unlike
	// chunks (content-addressed, immutable), a cached stale manifest would
	// make `voila pull` see an outdated image, so opt manifests out of edge
	// caching entirely. They are small and fetched once per pull, so the
	// origin cost is negligible.
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) putImage(w http.ResponseWriter, r *http.Request, ref string) {
	if r.ContentLength > maxImageBody {
		writeJSONError(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxImageBody)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSONError(w, "read body: "+err.Error(), http.StatusRequestEntityTooLarge)
		return
	}
	var m manifestJSON
	if err := json.Unmarshal(body, &m); err != nil {
		writeJSONError(w, "invalid image manifest: "+err.Error(), http.StatusBadRequest)
		return
	}
	// Refuse a manifest that does not self-identify with the URL's ref: the
	// flat hash-keyed file tree relies on the URL identifying the image; a
	// mismatched embedded image_ref would silently mislabel the stored
	// manifest. We do NOT rewrite m.ImageRef — the manifest is the source
	// of truth for what `voila pull` will write locally.
	if m.ImageRef != "" && m.ImageRef != ref {
		writeJSONError(w, "image_ref in manifest does not match URL ref", http.StatusBadRequest)
		return
	}
	if err := s.writeImage(ref, body); err != nil {
		writeJSONError(w, "store: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

// writeImage persists body (a JSON ImageManifest) atomically to
// <imageDir>/<sha256(ref) hex>.json.
func (s *Server) writeImage(ref string, body []byte) error {
	path := s.imagePath(ref)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err := tmp.Write(body); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

// imagePath returns the flat hash-keyed path for an image ref.
func (s *Server) imagePath(ref string) string {
	sum := sha256.Sum256([]byte(ref))
	return filepath.Join(s.imageDir, hex.EncodeToString(sum[:])+".json")
}

// --- helpers ---

// validChunkPath returns true iff p is exactly 64 lowercase hex chars.
func validChunkPath(p string) bool {
	if len(p) != 64 {
		return false
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// validRef rejects refs that could not have been produced by the client's
// url.QueryEscape (i.e. embedded NULs, or empty after unescaping). The ref
// here is already unescaped; we keep the check defense-in-depth.
func validRef(ref string) bool {
	if ref == "" || strings.Contains(ref, "\x00") {
		return false
	}
	return true
}

// chunkHash returns the BLAKE3-256 of buf — the same content-addressing hash
// the chunkstore uses — so a PUT body's id can be verified against the path
// without exposing chunkstore's internal hash function.
func chunkHash(buf []byte) chunkstore.ChunkID {
	return chunkstore.ChunkID(blake3.Sum256(buf))
}

// countingResponseWriter records the status code and byte count for the
// access-log middleware. The first WriteHeader sets status; subsequent calls
// are ignored (matches net/http's own behavior).
type countingResponseWriter struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (c *countingResponseWriter) WriteHeader(code int) {
	if c.wroteHeader {
		return
	}
	c.status = code
	c.wroteHeader = true
	c.ResponseWriter.WriteHeader(code)
}

func (c *countingResponseWriter) Write(p []byte) (int, error) {
	if !c.wroteHeader {
		c.wroteHeader = true
	}
	n, err := c.ResponseWriter.Write(p)
	c.bytes += int64(n)
	return n, err
}
