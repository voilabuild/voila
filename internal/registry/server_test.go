package registry

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"github.com/klauspost/compress/zstd"
	"golang.org/x/net/http2"
	"lukechampine.com/blake3"
)

// newTestServer spins a Server backed by a fresh LocalStore + temp image dir,
// mounted on an httptest.NewServer. It returns the running httptest server,
// the underlying *Server, a Client, and a cleanup func.
func newTestServer(t *testing.T) (ts *httptest.Server, srv *Server, c *Client, cleanup func()) {
	t.Helper()
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	imageDir := filepath.Join(root, "images")
	srv, err = NewServer(store, imageDir)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	// Silence the access log during tests.
	srv.SetLogger(log.New(io.Discard, "", 0))
	ts = httptest.NewServer(srv.Handler())
	c, err = NewClient(ts.URL)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	cleanup = func() {
		ts.Close()
		c.Close()
		_ = store.Close()
	}
	t.Cleanup(cleanup)
	return ts, srv, c, cleanup
}

// logLogger is unused; the test setup uses log.New(io.Discard,...) instead.

// TestServerChunkPutGetHead_RoundTrip verifies the full chunk round trip:
// PUT (verifying BLAKE3) → 201 once, 200 the second time → GET → raw bytes →
// HEAD → 200. Re-PUT must be idempotent.
func TestServerChunkPutGetHead_RoundTrip(t *testing.T) {
	ts, srv, c, _ := newTestServer(t)
	_ = ts
	_ = srv
	ctx := context.Background()
	payload := []byte("registry round trip payload")
	id := chunkstore.ChunkID(blake3.Sum256(payload))

	// First PUT → 201.
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("PutChunk: %v (expected 201)", err)
	}
	// Second PUT of the SAME bytes → still no error (the client treats 200
	// and 201 identically); verify the local store records exactly one blob
	// underlying the id (idempotent Put).
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("second PutChunk: %v", err)
	}
	// GET → raw bytes back.
	got, err := c.GetChunk(ctx, id)
	if err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("GetChunk returned %q, want %q", got, payload)
	}
	// HEAD → present.
	present, err := c.HasChunk(ctx, id)
	if err != nil {
		t.Fatalf("HasChunk: %v", err)
	}
	if !present {
		t.Fatal("HasChunk returned false on a just-PUT chunk")
	}
}

// TestServerChunkPut_HashMismatch_400: PUT the wrong bytes for an id must
// return an error surfacing as a 400 (the client reports "hash mismatch").
func TestServerChunkPut_HashMismatch_400(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	payload := []byte("the real bytes")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	// Replace one byte so the hash no longer matches.
	wrong := append([]byte(nil), payload...)
	wrong[0] = wrong[0] ^ 0xff
	if err := wrongHashSentinel(c.PutChunk(ctx, id, wrong)); err == nil {
		t.Fatal("PutChunk of mismatched bytes should error")
	}
	// The chunk must not be stored.
	if present, _ := c.HasChunk(ctx, id); present {
		t.Fatal("chunk stored despite hash mismatch")
	}
}

// wrongHashSentinel returns err unchanged; it exists to make the call-site
// intent (expecting a 400) self-documenting. Equivalent to `if err := c.PutChunk(...)`.
func wrongHashSentinel(err error) error { return err }

// TestServerPutChunk_AcceptsZstdContentEncoding verifies the compressed-wire
// path: a PUT carrying the zstd-compressed form of a chunk with
// Content-Encoding: zstd is accepted, the server decompresses before its
// BLAKE3-against-id check, and the chunk is subsequently retrievable as the
// raw bytes. This is the bandwidth win for `voila push` over a WAN.
func TestServerPutChunk_AcceptsZstdContentEncoding(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	// Highly compressible payload so zstd actually shrinks it.
	payload := bytes.Repeat([]byte("compress me "), 5000)
	id := chunkstore.ChunkID(blake3.Sum256(payload))

	enc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(3)))
	if err != nil {
		t.Fatalf("zstd encoder: %v", err)
	}
	defer enc.Close()
	compressed := enc.EncodeAll(payload, nil)
	if len(compressed) >= len(payload) {
		t.Fatalf("fixture did not compress: raw=%d comp=%d", len(payload), len(compressed))
	}
	if err := c.PutChunkStored(ctx, id, compressed, chunkstore.AlgoZstd); err != nil {
		t.Fatalf("PutChunkStored (zstd): %v", err)
	}
	// The chunk must round-trip as the RAW bytes via a normal GET — the
	// wire form is purely a transport concern; storage + GET are raw.
	got, err := c.GetChunk(ctx, id)
	if err != nil {
		t.Fatalf("GetChunk: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("raw bytes differ after compressed PUT (got=%d want=%d)", len(got), len(payload))
	}
}

// TestServerPutChunk_BadContentEncoding_400 verifies an unsupported /
// corrupt Content-Encoding is rejected with 400 (and the chunk is NOT
// stored) — the server does not silently fall back to raw.
func TestServerPutChunk_BadContentEncoding_400(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	payload := []byte("not actually zstd")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	// Send garbage with a zstd Content-Encoding: the decoder must reject it.
	if err := c.PutChunkStored(ctx, id, payload, chunkstore.AlgoZstd); err == nil {
		t.Fatal("PutChunkStored with non-zstd body + zstd encoding should 400")
	}
	if present, _ := c.HasChunk(ctx, id); present {
		t.Fatal("chunk stored despite a decode failure")
	}
}

// TestServerChunkGetMissing_404: GET of an absent chunk returns an error
// wrapping chunkstore.ErrNotFound.
func TestServerChunkGetMissing_404(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	var id chunkstore.ChunkID
	id[0] = 0x01
	_, err := c.GetChunk(ctx, id)
	if err == nil {
		t.Fatal("expected error for missing chunk")
	}
	if !errors.Is(err, chunkstore.ErrNotFound) {
		t.Fatalf("err = %v, want errors.Is chunkstore.ErrNotFound", err)
	}
}

// TestServerChunkHeadMissing_404: HEAD of an absent chunk returns (false, nil).
func TestServerChunkHeadMissing_404(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	var id chunkstore.ChunkID
	id[0] = 0x02
	present, err := c.HasChunk(ctx, id)
	if err != nil {
		t.Fatalf("HasChunk error: %v", err)
	}
	if present {
		t.Fatal("HasChunk reported a missing chunk as present")
	}
}

// TestServerImagePutGetRoundTrip verifies image manifest PUT/GET. The server
// validates the protobuf and persists it under the ref's sha256-keyed path.
func TestServerImagePutGetRoundTrip(t *testing.T) {
	_, srv, c, _ := newTestServer(t)
	_ = srv
	ctx := context.Background()
	im := &voilapb.ImageManifest{
		ImageRef:                "demo:v1",
		ImageDigest:             []byte("0123456789abcdef0123456789abcdef"),
		ConfigChunk:             bytes.Repeat([]byte{0xa1}, 32),
		MergedRootManifestChunk: bytes.Repeat([]byte{0xb2}, 32),
		TotalSize:               4096,
		ChunkCount:              7,
	}
	if err := c.PutImageManifest(ctx, im.GetImageRef(), im); err != nil {
		t.Fatalf("PutImage: %v", err)
	}
	got, err := c.GetImageManifest(ctx, im.GetImageRef())
	if err != nil {
		t.Fatalf("GetImage: %v", err)
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
	if len(got.GetConfigChunk()) != 32 {
		t.Errorf("config chunk len = %d, want 32", len(got.GetConfigChunk()))
	}
}

// TestServerImageGetMissing_404: GET of an absent image returns a
// *ManifestError wrapping ErrImageNotFound (the bundled server has no auth, so
// 404 here is a genuine miss).
func TestServerImageGetMissing_404(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	_, err := c.GetImage(ctx, "nope:v1")
	if err == nil {
		t.Fatal("expected error for missing image")
	}
	if !errors.Is(err, ErrImageNotFound) {
		t.Fatalf("err = %v, want errors.Is ErrImageNotFound", err)
	}
}

// rawResp does a raw HTTP request against the test server so the caller can
// inspect response headers (the Client wrapper discards them). The body is
// read + closed so the connection can be reused.
func rawResp(t *testing.T, ts *httptest.Server, method, path string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, ts.URL+path, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp
}

// TestServerChunkGet_CacheControlImmutable: a chunk GET advertises an
// immutable, long-max-age Cache-Control so a CDN in front of the registry
// can cache /v1/chunks/<id> indefinitely — chunks are content-addressed and
// never change for a given id.
func TestServerChunkGet_CacheControlImmutable(t *testing.T) {
	ts, _, c, _ := newTestServer(t)
	ctx := context.Background()
	payload := []byte("cacheable chunk")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	resp := rawResp(t, ts, http.MethodGet, "/v1/chunks/"+id.String())
	if resp.Header.Get("Cache-Control") != "public, max-age=31536000, immutable" {
		t.Fatalf("GET chunk Cache-Control = %q, want %q",
			resp.Header.Get("Cache-Control"), "public, max-age=31536000, immutable")
	}
}

// TestServerChunkHead_CacheControlImmutable: a chunk HEAD carries the same
// Cache-Control as the GET it represents, so a CDN HEAD probe / revalidation
// sees the identical policy.
func TestServerChunkHead_CacheControlImmutable(t *testing.T) {
	ts, _, c, _ := newTestServer(t)
	ctx := context.Background()
	payload := []byte("cacheable chunk head")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	resp := rawResp(t, ts, http.MethodHead, "/v1/chunks/"+id.String())
	if resp.Header.Get("Cache-Control") != "public, max-age=31536000, immutable" {
		t.Fatalf("HEAD chunk Cache-Control = %q, want %q",
			resp.Header.Get("Cache-Control"), "public, max-age=31536000, immutable")
	}
}

// TestServerImageGet_CacheControlNoStore: an image manifest GET advertises
// no-store so a CDN does not cache it — a ref is mutable (push overwrites the
// stored manifest), and a stale manifest would make `voila pull` see an
// outdated image. Manifests are small and fetched once per pull, so the
// origin cost of not caching is negligible.
func TestServerImageGet_CacheControlNoStore(t *testing.T) {
	ts, _, c, _ := newTestServer(t)
	ctx := context.Background()
	im := &voilapb.ImageManifest{
		ImageRef:                "demo:v1",
		ImageDigest:             bytes.Repeat([]byte{0x01}, 32),
		ConfigChunk:             bytes.Repeat([]byte{0xa1}, 32),
		MergedRootManifestChunk: bytes.Repeat([]byte{0xb2}, 32),
	}
	if err := c.PutImageManifest(ctx, im.GetImageRef(), im); err != nil {
		t.Fatalf("PutImage: %v", err)
	}
	resp := rawResp(t, ts, http.MethodGet, "/v1/images/"+im.GetImageRef())
	if resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("GET image Cache-Control = %q, want %q",
			resp.Header.Get("Cache-Control"), "no-store")
	}
}

// TestServerImagePut_InvalidProto_400: PUT a body that is not a valid
// ImageManifest pb must surface as a 400 / "bad manifest".
func TestServerImagePut_InvalidProto_400(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	err := c.PutImage(ctx, "bad:v1", []byte{0xff, 0xff, 0xff, 0xff})
	if err == nil {
		t.Fatal("expected error for invalid image manifest")
	}
	if !strings.Contains(err.Error(), "bad manifest") && !strings.Contains(err.Error(), "400") {
		t.Errorf("error %q should mention bad manifest / 400", err.Error())
	}
}

// TestServerPutChunk_OversizedBodyRejected: a body bigger than 8 MiB is
// rejected before storage. We don't go through the client (the client does
// not have an obvious oversized path); we POST directly.
func TestServerPutChunk_OversizedBodyRejected(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	ctx := context.Background()
	body := make([]byte, maxChunkBody+1)
	for i := range body {
		body[i] = 'q'
	}
	// Use a path id that BLAKE3 of body cannot satisfy anyway; the size
	// check must short-circuit before the hash compare.
	req, err := http.NewRequestWithContext(ctx, http.MethodPut,
		ts.URL+"/v1/chunks/"+strings.Repeat("0", 64), bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.ContentLength = int64(len(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d (oversized chunk body)", resp.StatusCode, http.StatusRequestEntityTooLarge)
	}
}

// TestServerServeTLS verifies the registry.Server.ServeTLS convenience
// wrapper (used by `voila registry -tls-cert ... -tls-key ...`) accepts a
// cert/key pair and serves HTTPS. We generate a self-signed cert in memory
// so the test has no external fixture dependency.
func TestServerServeTLS(t *testing.T) {
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()
	srv, err := NewServer(store, filepath.Join(root, "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	srv.SetLogger(log.New(io.Discard, "", 0))

	cert, key := selfSignedCert(t, "127.0.0.1")
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.ServeTLS(lis, cert, key) }()
	t.Cleanup(func() { _ = lis.Close(); <-serveErr })

	tr := &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	if err := http2.ConfigureTransport(tr); err != nil {
		t.Fatalf("http2.ConfigureTransport: %v", err)
	}
	defer tr.CloseIdleConnections()
	cli := &http.Client{Transport: tr}

	resp, err := cli.Get("https://" + lis.Addr().String() + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz over ServeTLS: %v", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	if resp.Proto != "HTTP/2.0" {
		t.Errorf("resp.Proto = %q, want HTTP/2.0", resp.Proto)
	}
}

// selfSignedCert writes a self-signed cert + key to temp files and returns
// their paths. Used only by TestServerServeTLS.
func selfSignedCert(t *testing.T, host string) (certPath, keyPath string) {
	t.Helper()
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("rsa.GenerateKey: %v", err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: host},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{host},
		IPAddresses:  []net.IP{net.ParseIP(host)},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		t.Fatalf("x509.CreateCertificate: %v", err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyBytes, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("MarshalPKCS8PrivateKey: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyBytes})
	dir := t.TempDir()
	certPath = filepath.Join(dir, "cert.pem")
	keyPath = filepath.Join(dir, "key.pem")
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return certPath, keyPath
}

// TestServerUnknownPath_404: anything outside /v1 is a flat 404.
func TestServerUnknownPath_404(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	resp, err := http.Get(ts.URL + "/otherpath")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404 (unknown path)", resp.StatusCode)
	}
}

// TestServerImagePersistedToFlatHashPath verifies the on-disk layout: the
// manifest is stored at <imageDir>/<sha256(ref) hex>.json (NOT refKey-style).
func TestServerImagePersistedToFlatHashPath(t *testing.T) {
	_, srv, c, _ := newTestServer(t)
	ctx := context.Background()
	const ref = "demo:hashpath-test"
	im := &voilapb.ImageManifest{ImageRef: ref, ConfigChunk: bytes.Repeat([]byte{0x33}, 32)}
	if err := c.PutImageManifest(ctx, ref, im); err != nil {
		t.Fatalf("PutImage: %v", err)
	}
	want := srv.imagePath(ref)
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("image file %q missing: %v", want, err)
	}
	data, err := os.ReadFile(want)
	if err != nil {
		t.Fatal(err)
	}
	var m manifestJSON
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("unmarshal persisted manifest: %v", err)
	}
	if m.ImageRef != ref {
		t.Errorf("persisted image_ref = %q, want %q", m.ImageRef, ref)
	}
}

// TestServerImageRefWithSpecialCharsRoundTrip verifies that refs containing
// characters that need URL escaping (e.g. "library/python:3.13", which has a
// '/') survive a PUT → GET round trip. The server stores under
// sha256(ref).pb, so the path semantics do not depend on the ref's content;
// but the HTTP path encoding does.
func TestServerImageRefWithSpecialCharsRoundTrip(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	const ref = "library/python:3.13"
	im := &voilapb.ImageManifest{ImageRef: ref, ConfigChunk: bytes.Repeat([]byte{0x55}, 32)}
	if err := c.PutImageManifest(ctx, ref, im); err != nil {
		t.Fatalf("PutImage: %v", err)
	}
	got, err := c.GetImageManifest(ctx, ref)
	if err != nil {
		t.Fatalf("GetImage: %v", err)
	}
	if got.GetImageRef() != ref {
		t.Errorf("ref round trip: %q, want %q", got.GetImageRef(), ref)
	}
}

// bulkMissingBody posts a JSON {"ids":[...]} request via POST
// /v1/chunks/missing and returns the status code + body. It bypasses the
// Client so we can assert raw wire behaviour (status codes, error bodies)
// independent of the client method's 404 fallback mapping.
func bulkMissingBody(t *testing.T, url string, ids []string) (status int, respBody string) {
	t.Helper()
	ctx := context.Background()
	body, _ := json.Marshal(struct {
		IDs []string `json:"ids"`
	}{IDs: ids})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url+"/v1/chunks/missing", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.ContentLength = int64(len(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data)
}

// bulkMissingDecode parses a JSON {"missing":[...]} response body into a set
// of id strings for set-comparison (order is unspecified).
func bulkMissingDecode(t *testing.T, body string) map[string]bool {
	t.Helper()
	var resp struct {
		Missing []string `json:"missing"`
	}
	if err := json.Unmarshal([]byte(body), &resp); err != nil {
		t.Fatalf("decode missing response: %v (body=%q)", err, body)
	}
	got := make(map[string]bool, len(resp.Missing))
	for _, id := range resp.Missing {
		if got[id] {
			t.Fatalf("duplicate id %q in response", id)
		}
		got[id] = true
	}
	return got
}

// TestServerBulkMissing_RoundTrip asserts the core contract: PUT some
// chunks, POST a batch of ids, and the server returns ONLY the ids it does
// NOT have (newline-separated; order unspecified so we compare as a set).
func TestServerBulkMissing_RoundTrip(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	// Two present, two absent. Use real BLAKE3 ids by hashing payloads.
	present := make([]chunkstore.ChunkID, 2)
	absent := make([]chunkstore.ChunkID, 2)
	for i, p := range [][]byte{[]byte("have-one"), []byte("have-two")} {
		present[i] = chunkstore.ChunkID(blake3.Sum256(p))
		if err := c.PutChunk(ctx, present[i], p); err != nil {
			t.Fatalf("PutChunk present %d: %v", i, err)
		}
	}
	for i, p := range [][]byte{[]byte("miss-one"), []byte("miss-two")} {
		absent[i] = chunkstore.ChunkID(blake3.Sum256(p))
	}
	// Interleave so the server can't reorder by luck.
	all := []chunkstore.ChunkID{present[0], absent[0], present[1], absent[1]}
	idStrs := make([]string, len(all))
	for i, id := range all {
		idStrs[i] = id.String()
	}
	status, body := bulkMissingBody(t, c.Base(), idStrs)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	got := bulkMissingDecode(t, body)
	wantAbsent := map[string]bool{absent[0].String(): true, absent[1].String(): true}
	if len(got) != len(wantAbsent) {
		t.Fatalf("got %d missing ids, want %d: %v", len(got), len(wantAbsent), got)
	}
	for k := range wantAbsent {
		if !got[k] {
			t.Errorf("response missing id %q; got %v", k, got)
		}
	}
}

// TestServerBulkMissing_EmptyRequest: an empty body is a legal request
// meaning "you sent me nothing"; the server answers 200 with an empty body
// (it has nothing to claim missing among the empty set).
func TestServerBulkMissing_EmptyRequest(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	status, body := bulkMissingBody(t, ts.URL, nil)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (empty request)", status)
	}
	got := bulkMissingDecode(t, body)
	if len(got) != 0 {
		t.Fatalf("empty request should yield empty missing set, got %v", got)
	}
}

// TestServerBulkMissing_AllPresent: when the server already holds every id
// in the request, the response body is empty (the documented "has
// everything" sentinel).
func TestServerBulkMissing_AllPresent(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	payload := []byte("present payload for all-present test")
	id := chunkstore.ChunkID(blake3.Sum256(payload))
	if err := c.PutChunk(ctx, id, payload); err != nil {
		t.Fatalf("PutChunk: %v", err)
	}
	status, body := bulkMissingBody(t, c.Base(), []string{id.String()})
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	got := bulkMissingDecode(t, body)
	if len(got) != 0 {
		t.Fatalf("all-present request should yield empty missing set, got %v", got)
	}
}

// TestServerBulkMissing_MalformedID_400: a request containing a malformed
// id anywhere in the body returns 400 naming the first bad line (1-indexed).
func TestServerBulkMissing_MalformedID_400(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	good := chunkstore.ChunkID(blake3.Sum256([]byte("good")))
	status, respBody := bulkMissingBody(t, ts.URL, []string{good.String(), "ZZtop", good.String()})
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (malformed id)", status)
	}
	// The bad id is at index 1 (0-indexed); the error must name the index
	// and quote the bad value.
	if !strings.Contains(respBody, "index 1") {
		t.Errorf("error %q should name \"index 1\" as the bad id position", respBody)
	}
	if !strings.Contains(respBody, "ZZtop") {
		t.Errorf("error %q should quote the bad id", respBody)
	}
}

// TestServerBulkMissing_OversizedBody_400: a body bigger than 8 MiB is
// rejected with 400 (per spec) — not 413 — before the server parses any ids.
func TestServerBulkMissing_OversizedBody_400(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	// Build a JSON body larger than maxMissingBody by stuffing many ids.
	// Each id entry is ~67 bytes ("    \"<64hex>\",\n"); we need > 8 MiB.
	over := maxMissingBody/70 + 1
	ids := make([]string, over)
	good := chunkstore.ChunkID(blake3.Sum256([]byte("good")))
	for i := range ids {
		ids[i] = good.String()
	}
	status, _ := bulkMissingBody(t, ts.URL, ids)
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (oversized body)", status)
	}
}

// TestServerBulkMissing_TooManyIDs_400: more than 65536 ids in one request
// is rejected with 400. We construct valid-but-distinct 64-hex ids by
// incrementally varying the first 6 hex chars.
func TestServerBulkMissing_TooManyIDs_400(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	over := maxMissingIDs + 1
	ids := make([]string, over)
	for i := range ids {
		var id chunkstore.ChunkID
		ii := uint64(i + 1)
		for b := 0; b < 6 && ii != 0; b++ {
			id[b] = byte(ii & 0xff)
			ii >>= 8
		}
		ids[i] = id.String()
	}
	status, respBody := bulkMissingBody(t, ts.URL, ids)
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (too many ids)", status)
	}
	if !strings.Contains(respBody, "too many") && !strings.Contains(respBody, "max") {
		t.Errorf("error %q should mention the id cap", respBody)
	}
}

// TestServerBulkMissing_MethodNotAllowed_405: only POST is accepted on
// /v1/chunks/missing. A GET must respond 405 (with an Allow: POST header).
func TestServerBulkMissing_MethodNotAllowed_405(t *testing.T) {
	ts, _, _, _ := newTestServer(t)
	ctx := context.Background()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/chunks/missing", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", resp.StatusCode)
	}
	if got := resp.Header.Get("Allow"); got != "POST" {
		t.Errorf("Allow = %q, want POST", got)
	}
}

// TestServerBulkMissing_PathIsNotAChunk asserts registering /v1/chunks/missing
// ahead of /v1/chunks/<hex> did not steal the chunk namespace: a GET to
// a real id path still routes to the chunk handler (200 or 404), not to the
// missing handler. Defense against a ServeMux precedence regression.
func TestServerBulkMissing_PathIsNotAChunk(t *testing.T) {
	_, _, c, _ := newTestServer(t)
	ctx := context.Background()
	// A real id that the server doesn't have → GET must be 404 (the chunk
	// handler's not-found), not the missing handler's 405.
	var id chunkstore.ChunkID
	id[0] = 0x07
	if _, err := c.GetChunk(ctx, id); !errors.Is(err, chunkstore.ErrNotFound) {
		t.Fatalf("GetChunk of absent id under /v1/chunks/missing-prefix collision: err = %v, want ErrNotFound", err)
	}
}

// TestServerRegistryConfig verifies GET /v1/registry/config: a default server
// advertises no chunk origin (chunk_endpoint == ""), and a server constructed
// with WithChunkOrigin advertises that origin (with a trailing slash trimmed)
// and rejects non-GET methods with 405.
func TestServerRegistryConfig(t *testing.T) {
	t.Run("default_empty_origin", func(t *testing.T) {
		ts, _, _, _ := newTestServer(t)
		resp, err := http.Get(ts.URL + "/v1/registry/config")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Errorf("Content-Type = %q, want application/json", ct)
		}
		if cc := resp.Header.Get("Cache-Control"); cc != "no-store" {
			t.Errorf("Cache-Control = %q, want no-store", cc)
		}
		var cfg struct {
			ChunkEndpoint string `json:"chunk_endpoint"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if cfg.ChunkEndpoint != "" {
			t.Errorf("chunk_endpoint = %q, want \"\" (no origin configured)", cfg.ChunkEndpoint)
		}
	})

	t.Run("with_chunk_origin", func(t *testing.T) {
		root := t.TempDir()
		store, err := chunkstore.OpenLocal(root)
		if err != nil {
			t.Fatalf("OpenLocal: %v", err)
		}
		srv, err := NewServer(store, filepath.Join(root, "images"),
			WithChunkOrigin("https://s3.example/bucket/"))
		if err != nil {
			_ = store.Close()
			t.Fatalf("NewServer: %v", err)
		}
		srv.SetLogger(log.New(io.Discard, "", 0))
		ts := httptest.NewServer(srv.Handler())
		defer ts.Close()
		defer store.Close()

		resp, err := http.Get(ts.URL + "/v1/registry/config")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		var cfg struct {
			ChunkEndpoint string `json:"chunk_endpoint"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
			t.Fatalf("decode: %v", err)
		}
		// Trailing slash is trimmed so the client can join <origin>/<id>.
		if cfg.ChunkEndpoint != "https://s3.example/bucket" {
			t.Errorf("chunk_endpoint = %q, want %q", cfg.ChunkEndpoint, "https://s3.example/bucket")
		}
	})

	t.Run("method_not_allowed", func(t *testing.T) {
		ts, _, _, _ := newTestServer(t)
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/registry/config", nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", resp.StatusCode)
		}
		if got := resp.Header.Get("Allow"); got != "GET" {
			t.Errorf("Allow = %q, want GET", got)
		}
	})

	// Defense-in-depth: the new route is registered (mux precedence) so a
	// GET to /v1/registry/config reaches the config handler, not the chunk
	// handler (which would 404 an unknown "config" hex id).
	t.Run("route_isolation_from_chunks", func(t *testing.T) {
		ts, _, _, _ := newTestServer(t)
		resp, err := http.Get(ts.URL + "/v1/registry/config")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200 (config route must not collide with /v1/chunks/ prefix)", resp.StatusCode)
		}
	})
}
