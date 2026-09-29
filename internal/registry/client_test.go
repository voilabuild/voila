package registry

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"lukechampine.com/blake3"
)

// TestNewClient_RejectsInvalidURLs covers a few obvious bad inputs: the
// client returns a clear error rather than panicking later inside net/http.
func TestNewClient_RejectsInvalidURLs(t *testing.T) {
	for _, in := range []string{"", "not a url", "foo://", "://bar"} {
		if _, err := NewClient(in); err == nil {
			t.Errorf("NewClient(%q) = nil, want error", in)
		}
	}
	for _, in := range []string{"http://localhost:7423", "http://example.test/", "https://registry.example.io/v0"} {
		if _, err := NewClient(in); err != nil {
			t.Errorf("NewClient(%q) err = %v", in, err)
		}
	}
}

// TestNewClient_TunedTransport verifies the client uses a custom *http.Transport
// (not http.DefaultTransport) sized for the push fan-out: a high per-host
// idle-connection cap so 64 concurrent PUTs reuse connections, and
// ForceAttemptHTTP2 so an https:// registry negotiates h2 (multiplexing the
// fan-out on one TCP+TLS connection). A regression that drops back to the
// stdlib defaults (MaxIdleConnsPerHost=2, no h2) would be caught here.
func TestNewClient_TunedTransport(t *testing.T) {
	c, err := NewClient("https://registry.example.test")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	tr, ok := c.httpc.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("Transport = %T, want *http.Transport", c.httpc.Transport)
	}
	if tr.MaxIdleConnsPerHost < 64 {
		t.Errorf("MaxIdleConnsPerHost = %d, want >= 64 (push fan-out)", tr.MaxIdleConnsPerHost)
	}
	if !tr.ForceAttemptHTTP2 {
		t.Errorf("ForceAttemptHTTP2 = false, want true (https:// registry should negotiate h2)")
	}
	if c.httpc.Timeout != 0 {
		t.Errorf("Client.Timeout = %v, want 0 (per-request deadlines belong to context, not a blanket timeout that kills slow uploads)", c.httpc.Timeout)
	}
}

// TestNewClient_WithTokenSendsBearerAuth verifies that a client constructed
// with WithToken sends `Authorization: Bearer <token>` on every request
// (chunk GET/HEAD/PUT, missing, image GET/PUT, and the discovery fetch), and
// that a client with no token sends no Authorization header at all. A
// regression that drops the header would make every request 401 against an
// authenticated registry.
func TestNewClient_WithTokenSendsBearerAuth(t *testing.T) {
	const token = "dreg_testtoken"
	// seen tracks the Authorization header per route, guarded by a mutex
	// because the push fan-out / discovery can race.
	var mu sync.Mutex
	seen := map[string]string{}
	record := func(r *http.Request) {
		mu.Lock()
		seen[r.Method+" "+r.URL.Path] = r.Header.Get("Authorization")
		mu.Unlock()
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		record(r)
		switch {
		case r.URL.Path == "/v1/registry/config":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{}`))
		case r.URL.Path == "/v1/chunks/missing" && r.Method == http.MethodPost:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"missing":[]}`))
		case strings.HasPrefix(r.URL.Path, "/v1/chunks/"):
			if r.Method == http.MethodPut {
				body, _ := io.ReadAll(r.Body)
				// The wire format is zstd: decompress before hashing so the
				// BLAKE3 check matches the id (hash of the RAW bytes).
				if enc := r.Header.Get("Content-Encoding"); strings.EqualFold(enc, "zstd") {
					decoded, derr := chunkstore.DecodeStored(body, chunkstore.AlgoZstd)
					if derr != nil {
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					body = decoded
				}
				if id := chunkstore.ChunkID(blake3.Sum256(body)); id.String() == strings.TrimPrefix(r.URL.Path, "/v1/chunks/") {
					w.WriteHeader(http.StatusCreated)
				} else {
					w.WriteHeader(http.StatusBadRequest)
				}
			} else {
				w.WriteHeader(http.StatusOK)
			}
		case strings.HasPrefix(r.URL.Path, "/v1/images/"):
			if r.Method == http.MethodPut {
				w.WriteHeader(http.StatusCreated)
			} else {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"image_ref":"x/y:z"}`))
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c, err := NewClient(srv.URL, WithToken(token))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ctx := context.Background()

	// Exercise one of each request kind.
	id := chunkstore.ChunkID(blake3.Sum256([]byte("payload")))
	if _, err := c.GetChunk(ctx, id); err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	if _, err := c.HasChunk(ctx, id); err != nil {
		t.Fatalf("HasChunk: %v", err)
	}
	if err := c.PutChunk(ctx, id, []byte("payload")); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	if _, err := c.MissingChunks(ctx, []chunkstore.ChunkID{id}); err != nil {
		t.Fatalf("MissingChunks: %v", err)
	}
	if _, err := c.GetImage(ctx, "x/y:z"); err != nil {
		t.Fatalf("GetImage: %v", err)
	}
	if err := c.PutImage(ctx, "x/y:z", []byte(`{"image_ref":"x/y:z"}`)); err != nil {
		t.Fatalf("PutImage: %v", err)
	}

	want := "Bearer " + token
	// Authenticated routes: HEAD/PUT/missing/image/discovery all carry the
	// bearer token. Chunk GET is deliberately unauthenticated (see
	// GetChunk) so a CDN/edge can cache the public, immutable chunk bytes.
	authed := []string{
		"GET /v1/registry/config",
		"HEAD /v1/chunks/" + id.String(),
		"PUT /v1/chunks/" + id.String(),
		"POST /v1/chunks/missing",
		"GET /v1/images/x/y:z",
		"PUT /v1/images/x/y:z",
	}
	for _, route := range authed {
		mu.Lock()
		got := seen[route]
		mu.Unlock()
		if got != want {
			t.Errorf("auth header on %s = %q, want %q", route, got, want)
		}
	}
	mu.Lock()
	chunkGet := seen["GET /v1/chunks/"+id.String()]
	mu.Unlock()
	if chunkGet != "" {
		t.Errorf("auth header on chunk GET = %q, want empty (CDN-cacheable, public)", chunkGet)
	}

	// No-token client sends no Authorization header on any request.
	c2, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	mu.Lock()
	before := len(seen)
	mu.Unlock()
	if _, err := c2.GetChunk(ctx, id); err != nil {
		t.Fatalf("GetChunk (no token): %v", err)
	}
	mu.Lock()
	gotNone := seen["GET /v1/chunks/"+id.String()]
	after := len(seen)
	mu.Unlock()
	if gotNone != "" {
		t.Errorf("no-token client sent Authorization = %q, want empty", gotNone)
	}
	if after != before {
		t.Errorf("no-token client changed seen map size: %d -> %d", before, after)
	}
}

// TestNewClient_PutChunkStoredSendsContentEncoding verifies the wire contract:
// both PutChunkStored and PutChunk send Content-Encoding: zstd (the wire
// format is always zstd; a raw body is compressed in putChunk before sending).
// A regression that drops the header would make the server reject the PUT.
func TestNewClient_PutChunkStoredSendsContentEncoding(t *testing.T) {
	var gotEncoding string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotEncoding = r.Header.Get("Content-Encoding")
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	defer srv.Close()
	c, _ := NewClient(srv.URL)
	defer c.Close()

	if err := c.PutChunkStored(context.Background(), chunkstore.ChunkID{}, []byte("x"), chunkstore.AlgoZstd); err != nil {
		t.Fatalf("PutChunkStored: %v", err)
	}
	if gotEncoding != "zstd" {
		t.Errorf("PutChunkStored Content-Encoding = %q, want %q", gotEncoding, "zstd")
	}
	if err := c.PutChunk(context.Background(), chunkstore.ChunkID{}, []byte("x")); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	if gotEncoding != "zstd" {
		t.Errorf("PutChunk Content-Encoding = %q, want %q (wire is always zstd)", gotEncoding, "zstd")
	}
}

// TestNewClient_TrimsTrailingSlash verifies the base URL keeps a single
// canonical form so subsequent path joins do not produce // doubling.
func TestNewClient_TrimsTrailingSlash(t *testing.T) {
	for _, in := range []string{"http://localhost:7423", "http://localhost:7423/"} {
		c, err := NewClient(in)
		if err != nil {
			t.Fatal(err)
		}
		if c.Base() != "http://localhost:7423" {
			t.Errorf("base = %q, want %q (input %q)", c.Base(), "http://localhost:7423", in)
		}
	}
}

// TestClient_5xxSurfacesAsError ensures the client does NOT swallow a 500/502
// as a 404-style ErrNotFound — a distinction push/pull depend on to decide
// whether to retry vs fail-fast.
func TestClient_5xxSurfacesAsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()
	c, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ctx := context.Background()
	var id chunkstore.ChunkID
	id[0] = 0x3
	if _, err := c.GetChunk(ctx, id); err == nil {
		t.Fatal("expected error from 502")
	} else if errors.Is(err, chunkstore.ErrNotFound) {
		t.Fatalf("502 was mapped to ErrNotFound; must surface as transport error: %v", err)
	}
	if present, err := c.HasChunk(ctx, id); err == nil {
		t.Fatal("expected error from 502 on HEAD")
	} else if present {
		t.Fatal("502 reported chunk as present")
	}
}

// TestClient_PutChunkVerifiesStatusCodes exercises the response code mapping
// for PutChunk: 200 and 201 are success, anything else is an error.
func TestClient_PutChunkVerifiesStatusCodes(t *testing.T) {
	cases := []struct {
		status int
		wantOK bool
	}{
		{http.StatusOK, true},
		{http.StatusCreated, true},
		{http.StatusBadRequest, false},
		{http.StatusUnauthorized, false},
		{http.StatusInternalServerError, false},
	}
	for _, tc := range cases {
		t.Run(http.StatusText(tc.status), func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
			}))
			defer srv.Close()
			c, _ := NewClient(srv.URL)
			defer c.Close()
			err := c.PutChunk(context.Background(), chunkstore.ChunkID{}, []byte("x"))
			if tc.wantOK && err != nil {
				t.Fatalf("status %d: got err %v, want nil", tc.status, err)
			}
			if !tc.wantOK && err == nil {
				t.Fatalf("status %d: got nil, want error", tc.status)
			}
		})
	}
}

// TestClient_GetImage_StatusMapping exercises GetImage's error mapping as a
// table: each registry-level failure must surface as a *ManifestError with a
// human-readable top-line message AND an errors.Is-able sentinel cause
// (ErrImageNotFound for 404, ErrNotAuthorized for 401/403), while transport
// failures keep their underlying net/http error. The old mapping leaked
// chunkstore.ErrNotFound ("chunkstore: chunk not found: image ...") for what
// was a registry manifest miss — misleading on `voila pull`.
func TestClient_GetImage_StatusMapping(t *testing.T) {
	cases := []struct {
		name         string // subtest name
		status       int    // status the fake registry answers with
		wantSentinel error  // errors.Is target
		wantMsgSub   string // required substring of err.Error()
	}{
		{"404 not found", http.StatusNotFound, ErrImageNotFound,
			`image "x/y:z" not found on`},
		{"401 unauthorized", http.StatusUnauthorized, ErrNotAuthorized,
			`not authorized for image "x/y:z"`},
		{"403 forbidden", http.StatusForbidden, ErrNotAuthorized,
			`not authorized for image "x/y:z"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
			}))
			c, err := NewClient(srv.URL)
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			_, err = c.GetImage(context.Background(), "x/y:z")
			if err == nil {
				t.Fatalf("status %d: got nil error", tc.status)
			}
			var me *ManifestError
			if !errors.As(err, &me) {
				t.Fatalf("err = %T (%v), want *ManifestError", err, err)
			}
			if me.Ref != "x/y:z" {
				t.Errorf("ManifestError.Ref = %q, want x/y:z", me.Ref)
			}
			if tc.wantSentinel != nil && !errors.Is(err, tc.wantSentinel) {
				t.Errorf("err = %v, want errors.Is %v", err, tc.wantSentinel)
			}
			if !strings.Contains(err.Error(), tc.wantMsgSub) {
				t.Errorf("err.Error() = %q, want substring %q", err.Error(), tc.wantMsgSub)
			}
			// The internal chunkstore sentinel must NOT leak into manifest
			// fetches — it belongs to the chunk GET path only.
			if errors.Is(err, chunkstore.ErrNotFound) {
				t.Errorf("err = %v, must not wrap chunkstore.ErrNotFound", err)
			}
		})
	}

	// Transport failure: server unreachable → ManifestError wrapping the
	// net/http error, no sentinel.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close()
	c, err := NewClient(url)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_, err = c.GetImage(context.Background(), "x/y:z")
	if err == nil {
		t.Fatal("unreachable registry: got nil error")
	}
	var me *ManifestError
	if !errors.As(err, &me) {
		t.Fatalf("transport err = %T (%v), want *ManifestError", err, err)
	}
	if errors.Is(err, ErrImageNotFound) || errors.Is(err, ErrNotAuthorized) {
		t.Errorf("transport err = %v, must not map to a status sentinel", err)
	}
	if !strings.Contains(err.Error(), `fetching image "x/y:z"`) {
		t.Errorf("transport err.Error() = %q, want fetching-image prefix", err.Error())
	}
}

// TestClient_PutImageRoundTripsManifestWithServer exercises PutImageManifest +
// GetImageManifest against the real server side, asserting the manifest's
// fields survive the JSON wire round trip (not byte-for-byte — the wire is
// JSON now, so we compare the parsed proto fields). This is the wire-level
// contract test.
func TestClient_PutImageRoundTripsManifestWithServer(t *testing.T) {
	ts, _, c, _ := newTestServer(t)
	_ = ts
	ctx := context.Background()
	im := &voilapb.ImageManifest{
		ImageRef:                "roundtrip:v1",
		ImageDigest:             bytes.Repeat([]byte{0xde}, 32),
		ConfigChunk:             bytes.Repeat([]byte{0xad}, 32),
		MergedRootManifestChunk: bytes.Repeat([]byte{0xbe}, 32),
		TotalSize:               123456,
		ChunkCount:              42,
	}
	if err := c.PutImageManifest(ctx, im.GetImageRef(), im); err != nil {
		t.Fatalf("PutImageManifest: %v", err)
	}
	got, err := c.GetImageManifest(ctx, im.GetImageRef())
	if err != nil {
		t.Fatalf("GetImageManifest: %v", err)
	}
	if got.GetImageRef() != im.GetImageRef() {
		t.Errorf("image_ref = %q, want %q", got.GetImageRef(), im.GetImageRef())
	}
	if got.GetTotalSize() != im.GetTotalSize() {
		t.Errorf("total_size = %d, want %d", got.GetTotalSize(), im.GetTotalSize())
	}
	if got.GetChunkCount() != im.GetChunkCount() {
		t.Errorf("chunk_count = %d, want %d", got.GetChunkCount(), im.GetChunkCount())
	}
	if !bytes.Equal(got.GetImageDigest(), im.GetImageDigest()) {
		t.Errorf("image_digest = %x, want %x", got.GetImageDigest(), im.GetImageDigest())
	}
	if !bytes.Equal(got.GetConfigChunk(), im.GetConfigChunk()) {
		t.Errorf("config_chunk = %x, want %x", got.GetConfigChunk(), im.GetConfigChunk())
	}
	if !bytes.Equal(got.GetMergedRootManifestChunk(), im.GetMergedRootManifestChunk()) {
		t.Errorf("merged_root_manifest_chunk = %x, want %x", got.GetMergedRootManifestChunk(), im.GetMergedRootManifestChunk())
	}
}

// TestClient_BLAKE3VerificationIsServerSide exercises the contract that the
// CLIENT does not need to hash-check itself (the server does): even if the
// caller hands the client mismatched bytes for an id, the client must round
// trip and let the server reply with 400. We previously did this with the
// test fixture at the server test; here we confirm the client surface
// (the error message) so a regression in client-side error mapping would be
// caught at this layer too.
func TestClient_BLAKE3VerificationIsServerSide(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	payload := []byte("the canonical bytes")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	wrong := append([]byte(nil), payload...)
	wrong[0] ^= 0xff
	if err := c.PutChunk(context.Background(), id, wrong); err == nil {
		t.Fatal("client should surface the 400 from a mismatched-chunk PUT")
	}
}

// TestClient_ConcurrentGetChunksExercisesConcurrentSafeUse proves the
// underlying *http.Client's transport is goroutine-safe and the pool fans out
// many concurrent requests without serializing.
func TestClient_ConcurrentGetChunksExercisesConcurrentSafeUse(t *testing.T) {
	ts, srv, c, _ := newTestServer(t)
	_ = ts
	_ = srv
	ctx := context.Background()
	const payload = "concurrent get me"
	id := chunkstore.ChunkID(blake3.Sum256([]byte(payload)))
	if err := c.PutChunk(ctx, id, []byte(payload)); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	const goroutines = 32
	done := make(chan error, goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			got, err := c.GetChunk(ctx, id)
			if err != nil {
				done <- err
				return
			}
			if !bytes.Equal(got, []byte(payload)) {
				done <- errors.New("GetChunk mismatch under concurrency")
				return
			}
			done <- nil
		}()
	}
	for i := 0; i < goroutines; i++ {
		if err := <-done; err != nil {
			t.Fatalf("concurrent GetChunk[%d]: %v", i, err)
		}
	}
}

// TestClient_GetChunkRawBytesNotDecoded reaffirms the wire bytes are the
// raw uncompressed chunk: PUT raw → GET → identical bytes; the registry must
// not, e.g., return zstd-compressed bytes to the wire.
func TestClient_GetChunkRawBytesNotDecoded(t *testing.T) {
	ts, srv, c, _ := newTestServer(t)
	_ = ts
	_ = srv
	ctx := context.Background()
	// Highly compressible payload (so the LocalStore under the server will
	// store it zstd) — but the wire response must be the raw bytes.
	payload := bytes.Repeat([]byte("compress me "), 5000)
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	got, err := c.GetChunk(ctx, id)
	if err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("wire bytes differ from raw (len got=%d want=%d)", len(got), len(payload))
	}
}

// keep imports used.
var _ = io.Discard

// TestClient_MissingChunks_RoundTrip: against a real server, MissingChunks
// returns exactly the subset the server does not hold. Order is unspecified,
// so we compare as a set.
func TestClient_MissingChunks_RoundTrip(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	// Derive ids from the actual payloads we PUT (the server verifies BLAKE3
	// on PUT) — so PUT succeeds and the ids are stable for the request.
	presentPhrases := []string{"alpha-present", "beta-present"}
	present := make([]chunkstore.ChunkID, 0, len(presentPhrases))
	for _, p := range presentPhrases {
		id := chunkstore.ChunkID(blake3.Sum256([]byte(p)))
		present = append(present, id)
		if err := c.PutChunk(ctx, id, []byte(p)); err != nil {
			t.Fatalf("PutChunk: %v", err)
		}
	}
	absentPhrases := []string{"alpha-absent", "beta-absent", "gamma-absent"}
	absent := make([]chunkstore.ChunkID, 0, len(absentPhrases))
	for _, p := range absentPhrases {
		absent = append(absent, chunkstore.ChunkID(blake3.Sum256([]byte(p))))
	}
	req := append(append([]chunkstore.ChunkID{}, present...), absent...)
	got, err := c.MissingChunks(ctx, req)
	if err != nil {
		t.Fatalf("MissingChunks: %v", err)
	}
	gotSet := map[chunkstore.ChunkID]bool{}
	for _, id := range got {
		if gotSet[id] {
			t.Fatalf("duplicate id %s in response", id)
		}
		gotSet[id] = true
	}
	if len(gotSet) != len(absent) {
		t.Fatalf("got %d missing, want %d (got=%v)", len(gotSet), len(absent), gotSet)
	}
	for _, id := range absent {
		if !gotSet[id] {
			t.Errorf("absent id %s not reported missing: %v", id, gotSet)
		}
	}
	for _, id := range present {
		if gotSet[id] {
			t.Errorf("present id %s reported as missing: %v", id, gotSet)
		}
	}
}

// TestClient_MissingChunks_EmptyInput: a zero-length id slice must not
// perform any network round trip and returns (nil, nil).
func TestClient_MissingChunks_EmptyInput(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	got, err := c.MissingChunks(context.Background(), nil)
	if err != nil {
		t.Fatalf("MissingChunks(nil): %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("got %d ids, want 0", len(got))
	}
}

// TestClient_MissingChunks_BatchesAt16384: a request with more than
// missingBatchSize ids must be split into multiple POSTs of ≤ batch size. We
// count POSTs to /v1/chunks/missing and assert exactly ⌈N/batch⌉.
func TestClient_MissingChunks_BatchesAt16384(t *testing.T) {
	var posts int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/chunks/missing" && r.Method == http.MethodPost {
			atomic.AddInt32(&posts, 1)
			body, _ := io.ReadAll(r.Body)
			var req struct {
				IDs []string `json:"ids"`
			}
			_ = json.Unmarshal(body, &req)
			if len(req.IDs) > missingBatchSize {
				t.Errorf("batch of %d ids exceeds max %d", len(req.IDs), missingBatchSize)
			}
			// Say the server is missing everything it is asked about.
			resp, _ := json.Marshal(struct {
				Missing []string `json:"missing"`
			}{Missing: req.IDs})
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(resp)
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	c, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	const total = missingBatchSize*2 + 7 // expect ⌈total/batch⌉ = 3 batches
	ids := make([]chunkstore.ChunkID, total)
	for i := range ids {
		ids[i][0] = byte(i + 1)
	}
	got, err := c.MissingChunks(context.Background(), ids)
	if err != nil {
		t.Fatalf("MissingChunks: %v", err)
	}
	if len(got) != total {
		t.Errorf("got %d ids back, want %d", len(got), total)
	}
	if n := atomic.LoadInt32(&posts); n != 3 {
		t.Errorf("performed %d POSTs, want 3 (⌈%d/%d⌉)", n, total, missingBatchSize)
	}
}

// TestClient_MissingChunks_FallbackOn404: when the server answers 404 on
// /v1/chunks/missing (older registry), MissingChunks returns
// ErrBulkMissingUnsupported so the caller can fall back to per-chunk HEADs.
func TestClient_MissingChunks_FallbackOn404(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()
	c, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ids := []chunkstore.ChunkID{
		chunkstore.ChunkID(blake3.Sum256([]byte("x"))),
	}
	got, err := c.MissingChunks(context.Background(), ids)
	if !errors.Is(err, ErrBulkMissingUnsupported) {
		t.Fatalf("err = %v, want ErrBulkMissingUnsupported", err)
	}
	if got != nil {
		t.Errorf("got = %v, want nil on fallback", got)
	}
}

// TestClient_MissingChunks_BadRequestFromServer: a 400 from the server (e.g.
// malformed-line rejection) surfaces as a non-nil error that is NOT
// ErrBulkMissingUnsupported.
func TestClient_MissingChunks_BadRequestFromServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "malformed chunk id at line 3: \"oops\"", http.StatusBadRequest)
	}))
	defer srv.Close()
	c, err := NewClient(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ids := []chunkstore.ChunkID{
		chunkstore.ChunkID(blake3.Sum256([]byte("y"))),
	}
	_, err = c.MissingChunks(context.Background(), ids)
	if err == nil {
		t.Fatal("expected error from 400")
	}
	if errors.Is(err, ErrBulkMissingUnsupported) {
		t.Fatalf("400 mapped to ErrBulkMissingUnsupported; must surface as a real error: %v", err)
	}
}

// TestClient_GetChunkUsesAdvertisedOrigin verifies the "chunks live on another
// server" contract: when the registry advertises a chunk_endpoint, GetChunk
// fetches bytes from <origin>/<id> (S3/R2/CDN) and NEVER touches the registry's
// /v1/chunks/<id>. HasChunk (HEAD) stays on the registry (see HasChunk test).
func TestClient_GetChunkUsesAdvertisedOrigin(t *testing.T) {
	var registryChunkHits int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// <origin>/<64-hex-id>: echo the id back as the chunk for an
		// unambiguous assertion that the registry's id was forwarded.
		id := strings.TrimPrefix(r.URL.Path, "/")
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = io.WriteString(w, "chunk-bytes-for:"+id)
	}))
	defer origin.Close()

	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/registry/config":
			_ = json.NewEncoder(w).Encode(map[string]string{"chunk_endpoint": origin.URL})
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/chunks/"):
			atomic.AddInt32(&registryChunkHits, 1)
			t.Errorf("registry served a chunk GET — must come from origin only")
			http.Error(w, "registry must not serve chunks when an origin is advertised", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer reg.Close()

	c, err := NewClient(reg.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	// ChunkOrigin forces lazy discovery so we can assert it up front.
	if got := c.ChunkOrigin(); got != origin.URL {
		t.Fatalf("ChunkOrigin = %q, want %q", got, origin.URL)
	}

	ctx := context.Background()
	var id chunkstore.ChunkID
	id[0] = 0xab
	got, err := c.GetChunk(ctx, id)
	if err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	want := "chunk-bytes-for:" + id.String()
	if string(got) != want {
		t.Errorf("GetChunk = %q, want %q", got, want)
	}
	if atomic.LoadInt32(&registryChunkHits) != 0 {
		t.Errorf("registry served %d chunk GETs, want 0 (origin-advertised reroute)", registryChunkHits)
	}
}

// TestClient_GetChunkFallsBackWhenOriginEmpty covers the backward-compatible
// path: a registry advertising chunk_endpoint == "" leaves GetChunk on
// /v1/chunks/<id> (no origin hit).
func TestClient_GetChunkFallsBackWhenOriginEmpty(t *testing.T) {
	var registryChunkHits int32
	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/registry/config":
			_ = json.NewEncoder(w).Encode(map[string]string{"chunk_endpoint": ""})
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/chunks/"):
			atomic.AddInt32(&registryChunkHits, 1)
			_, _ = io.WriteString(w, "from-registry")
		default:
			http.NotFound(w, r)
		}
	}))
	defer reg.Close()

	c, _ := NewClient(reg.URL)
	defer c.Close()
	if got := c.ChunkOrigin(); got != "" {
		t.Fatalf("ChunkOrigin = %q, want \"\" (no origin configured)", got)
	}

	var id chunkstore.ChunkID
	id[0] = 0x09
	got, err := c.GetChunk(context.Background(), id)
	if err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	if string(got) != "from-registry" {
		t.Errorf("GetChunk = %q, want %q", got, "from-registry")
	}
	if atomic.LoadInt32(&registryChunkHits) != 1 {
		t.Errorf("registry chunk GETs = %d, want 1 (fallback to registry)", registryChunkHits)
	}
}

// TestClient_GetChunkFallbackOnOldRegistry covers the discovery-failure path: a
// registry without /v1/registry/config (404) must NOT break GetChunk — the
// client silently falls back to /v1/chunks/<id>.
func TestClient_GetChunkFallbackOnOldRegistry(t *testing.T) {
	var registryChunkHits int32
	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			if strings.HasPrefix(r.URL.Path, "/v1/chunks/") && !strings.HasPrefix(r.URL.Path, "/v1/chunks/missing") {
				atomic.AddInt32(&registryChunkHits, 1)
				_, _ = io.WriteString(w, "from-registry")
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer reg.Close()

	c, _ := NewClient(reg.URL)
	defer c.Close()
	if got := c.ChunkOrigin(); got != "" {
		t.Fatalf("ChunkOrigin = %q, want \"\" (config route absent => no origin)", got)
	}

	var id chunkstore.ChunkID
	id[0] = 0x0b
	got, err := c.GetChunk(context.Background(), id)
	if err != nil {
		t.Fatalf("GetChunk on registry without /v1/registry/config: %v", err)
	}
	if string(got) != "from-registry" {
		t.Errorf("GetChunk = %q, want %q", got, "from-registry")
	}
	if atomic.LoadInt32(&registryChunkHits) != 1 {
		t.Errorf("registry chunk GETs = %d, want 1 (fallback on discovery 404)", registryChunkHits)
	}
}

// TestClient_GetChunkFallsBackAfterConfig5xx covers the discovery-warning path:
// a registry that returns 5xx on /v1/registry/config (not a clean 404) must
// still fall back to /v1/chunks/<id> rather than failing the chunk fetch, and
// logs a warning once so the problem is not invisible.
func TestClient_GetChunkFallsBackAfterConfig5xx(t *testing.T) {
	var registryChunkHits int32
	reg := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v1/registry/config":
			http.Error(w, "config bork", http.StatusInternalServerError)
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/chunks/"):
			atomic.AddInt32(&registryChunkHits, 1)
			_, _ = io.WriteString(w, "from-registry")
		default:
			http.NotFound(w, r)
		}
	}))
	defer reg.Close()

	c, _ := NewClient(reg.URL)
	defer c.Close()
	// Discovery errors are non-fatal: ChunkOrigin reports "" (no origin).
	if got := c.ChunkOrigin(); got != "" {
		t.Fatalf("ChunkOrigin = %q, want \"\" after config 5xx", got)
	}

	var id chunkstore.ChunkID
	id[0] = 0x0d
	got, err := c.GetChunk(context.Background(), id)
	if err != nil {
		t.Fatalf("GetChunk fell back to registry but errored: %v", err)
	}
	if string(got) != "from-registry" {
		t.Errorf("GetChunk = %q, want %q", got, "from-registry")
	}
	if atomic.LoadInt32(&registryChunkHits) != 1 {
		t.Errorf("registry chunk GETs = %d, want 1 (fallback after config 5xx)", registryChunkHits)
	}
}
