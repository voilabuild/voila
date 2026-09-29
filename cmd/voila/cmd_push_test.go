package main

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
	"voila/internal/registry"
)

// countingHandler wraps an http.Handler with per-method counters. We use it
// to assert the bulk-stat negotiation path: during a "bulk-capable" push the
// wire carries ZERO HEAD requests to /v1/chunks/<hex> (the negotiation is a
// single POST /v1/chunks/missing instead).
type countingHandler struct {
	inner http.Handler

	heads int32 // HEAD requests to /v1/chunks/<hex>
	puts  int32 // PUT  requests to /v1/chunks/<hex>
	posts int32 // POST requests to /v1/chunks/missing
}

func newCountingHandler(inner http.Handler) *countingHandler {
	return &countingHandler{inner: inner}
}

// isChunkPath reports whether the URL path identifies a real chunk (i.e. is of
// the form /v1/chunks/<64-hex>) as opposed to the /v1/chunks/missing route.
func isChunkPath(p string) bool {
	if !strings.HasPrefix(p, "/v1/chunks/") {
		return false
	}
	tail := strings.TrimPrefix(p, "/v1/chunks/")
	if tail == "missing" {
		return false
	}
	return len(tail) == 64
}

func (h *countingHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodHead:
		if isChunkPath(r.URL.Path) {
			atomic.AddInt32(&h.heads, 1)
		}
	case http.MethodPut:
		if isChunkPath(r.URL.Path) {
			atomic.AddInt32(&h.puts, 1)
		}
	case http.MethodPost:
		if r.URL.Path == "/v1/chunks/missing" {
			atomic.AddInt32(&h.posts, 1)
		}
	}
	h.inner.ServeHTTP(w, r)
}

func (h *countingHandler) snapshot() (heads, puts, posts int32) {
	return atomic.LoadInt32(&h.heads), atomic.LoadInt32(&h.puts), atomic.LoadInt32(&h.posts)
}

// resolveLocalManifest reopens the root's image store + resolves `ref` to its
// ImageManifest. Used by the push tests to compute the reachable set for
// pre-seeding the registry's backing store (the push code path itself uses
// the same ingest.Reachable call against the local store).
func resolveLocalManifest(t *testing.T, root, ref string) *voilapb.ImageManifest {
	t.Helper()
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("openImageStore: %v", err)
	}
	defer imgStore.Close()
	im, _, err := imagestore.Resolve(imgStore, ref)
	if err != nil {
		t.Fatalf("resolveImage: %v", err)
	}
	return im
}

// reachableChunkIDs returns the chunk closure for im read from the local root,
// as a deterministic slice. Push uses the same ingest.Reachable call.
func reachableChunkIDs(t *testing.T, root string, im *voilapb.ImageManifest) []chunkstore.ChunkID {
	t.Helper()
	local, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer local.Close()
	ctx := context.Background()
	set, err := ingest.Reachable(ctx, local, []*voilapb.ImageManifest{im})
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}
	out := make([]chunkstore.ChunkID, 0, len(set))
	for id := range set {
		out = append(out, id)
	}
	if len(out) == 0 {
		t.Fatal("fixture produced zero reachable chunks; test fixture is too small")
	}
	return out
}

// seedRegistryStore writes every reachable chunk from the local root into the
// registry's backing LocalStore, EXCEPT the id at skipIdx in the ids slice
// (which is left absent so the push has exactly one chunk to upload). Returns
// the id that was left un-seeded.
func seedRegistryStore(t *testing.T, root string, regStore *chunkstore.LocalStore, ids []chunkstore.ChunkID, skipIdx int) chunkstore.ChunkID {
	t.Helper()
	local, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal local: %v", err)
	}
	defer local.Close()
	ctx := context.Background()
	if skipIdx < 0 || skipIdx >= len(ids) {
		t.Fatalf("skipIdx %d out of range (len=%d)", skipIdx, len(ids))
	}
	skip := ids[skipIdx]
	for i, id := range ids {
		if i == skipIdx {
			continue
		}
		data, err := local.Get(ctx, id)
		if err != nil {
			t.Fatalf("local.Get %s: %v", id, err)
		}
		if _, err := regStore.Put(data); err != nil {
			t.Fatalf("regStore.Put %s: %v", id, err)
		}
	}
	return skip
}

// newRegistryStore opens a fresh temp-dir-backed LocalStore and returns it.
// Tests then build their own registry.Server(s) over it with whatever
// counting/intercepting wrapper they need; the store is closed via cleanup.
func newRegistryStore(t *testing.T) *chunkstore.LocalStore {
	t.Helper()
	rootReg := t.TempDir()
	st, err := chunkstore.OpenLocal(rootReg)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

// TestCmdPush_UploadsOnlyMissing_NoHeadStorm asserts the bulk-stat
// negotiation path: given a registry that already holds every reachable
// chunk except one, a bulk-capable push uploads EXACTLY the one missing
// chunk and makes ZERO HEAD requests to /v1/chunks/<hex> (the negotiation
// uses POST /v1/chunks/missing instead). The summary line retains its shape.
func TestCmdPush_UploadsOnlyMissing_NoHeadStorm(t *testing.T) {
	const ref = "bulkstorm:v1"
	root, _ := ingestTinyFixture(t, ref)
	im := resolveLocalManifest(t, root, ref)
	ids := reachableChunkIDs(t, root, im)

	regStore := newRegistryStore(t)
	// Wrap the real registry handler with a counting wrapper so we can
	// pre-seed via store.Put *and* count wire traffic on the same server.
	regSrv, err := registry.NewServer(regStore, filepath.Join(t.TempDir(), "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	regSrv.SetLogger(log.New(io.Discard, "", 0))
	ch := newCountingHandler(regSrv.Handler())
	ts := httptest.NewServer(ch)
	t.Cleanup(ts.Close)

	// Leave out the first chunk — give the push exactly one chunk to upload.
	skip := seedRegistryStore(t, root, regStore, ids, 0)

	var out bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}},
		[]string{"-registry", ts.URL, ref}); err != nil {
		t.Fatalf("cmdPush: %v", err)
	}
	summary := out.String()
	if !strings.HasPrefix(summary, "pushed "+ref+": ") {
		t.Fatalf("summary line shape wrong: %q", summary)
	}
	// Exactly one chunk uploaded (the one we held back).
	if got := parseUploadedCount(t, summary); got != 1 {
		t.Errorf("uploaded = %d, want 1 (only the held-back chunk %s):\n%s", got, skip, summary)
	}
	// N-1 already present, where N is the closure size.
	wantAlready := len(ids) - 1
	gotAlready := parseAlreadyCount(t, summary)
	if gotAlready != wantAlready {
		t.Errorf("already present = %d, want %d: %s", gotAlready, wantAlready, summary)
	}

	heads, puts, posts := ch.snapshot()
	if heads != 0 {
		t.Errorf("HEAD storm: saw %d HEAD requests to /v1/chunks/ during a bulk-capable push; expected 0", heads)
	}
	if puts != 1 {
		t.Errorf("PUT count = %d, want 1 (only the held-back chunk): %s", puts, summary)
	}
	if posts == 0 {
		t.Errorf("expected at least one POST /v1/chunks/missing (the bulk negotiation); got 0")
	}
}

// TestCmdPush_FallbackToHeadsOn404 simulates an older registry that answers
// 404 on POST /v1/chunks/missing: push must still succeed by falling back to
// the per-chunk HEAD negotiation path, and the summary line retains the same
// shape as the bulk path. The push issues HEADs for every reachable chunk
// and uploads the one that is missing.
func TestCmdPush_FallbackToHeadsOn404(t *testing.T) {
	const ref = "fbhead:v1"
	root, _ := ingestTinyFixture(t, ref)
	im := resolveLocalManifest(t, root, ref)
	ids := reachableChunkIDs(t, root, im)

	// Build the real registry over a fresh backing store, but wrap it with
	// an outer handler that 404s POST /v1/chunks/missing (older registry).
	// The inner countingHandler sits inside the interceptor so we still see
	// the HEAD/PUT traffic of the fallback path; the intercepted POST never
	// reaches it (posts stays 0).
	regRoot := t.TempDir()
	regStore, err := chunkstore.OpenLocal(regRoot)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	srv, err := registry.NewServer(regStore, filepath.Join(regRoot, "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	srv.SetLogger(log.New(io.Discard, "", 0))
	ch := newCountingHandler(srv.Handler())
	outer := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && r.URL.Path == "/v1/chunks/missing" {
			_, _ = io.Copy(io.Discard, r.Body)
			http.NotFound(w, r)
			return
		}
		ch.ServeHTTP(w, r)
	})
	ts := httptest.NewServer(outer)
	t.Cleanup(func() {
		ts.Close()
		_ = regStore.Close()
	})

	// Pre-seed the registry with every reachable chunk EXCEPT the last one,
	// so HEAD confirms presence for N-1 and the push uploads exactly one.
	seedRegistryStore(t, root, regStore, ids, len(ids)-1)

	var out bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}},
		[]string{"-registry", ts.URL, ref}); err != nil {
		t.Fatalf("cmdPush (fallback): %v", err)
	}
	summary := out.String()
	if !strings.HasPrefix(summary, "pushed "+ref+": ") {
		t.Fatalf("summary line shape wrong: %q", summary)
	}
	if got := parseUploadedCount(t, summary); got != 1 {
		t.Errorf("uploaded = %d, want 1 (the one chunk not pre-seeded): %s", got, summary)
	}
	wantAlready := len(ids) - 1
	if got := parseAlreadyCount(t, summary); got != wantAlready {
		t.Errorf("already present = %d, want %d: %s", got, wantAlready, summary)
	}

	// The fallback path HEADs every reachable chunk once and PUTs the one
	// miss; the probe POST was intercepted before the inner countingHandler,
	// so posts stays 0.
	heads, puts, posts := ch.snapshot()
	if heads != int32(len(ids)) {
		t.Errorf("HEAD count = %d, want %d (one HEAD per reachable chunk in fallback): %s", heads, len(ids), summary)
	}
	if puts != 1 {
		t.Errorf("PUT count = %d, want 1 (only the held-back chunk): %s", puts, summary)
	}
	if posts != 0 {
		t.Errorf("inner POST counter = %d, want 0 (the 404 was intercepted before the inner handler)", posts)
	}

	// Sanity: the manifest must have landed on the registry too.
	cl, err := registry.NewClient(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()
	if _, err := cl.GetImageManifest(context.Background(), ref); err != nil {
		t.Fatalf("registry should hold the pushed manifest after fallback push: %v", err)
	}
}

// parseAlreadyCount extracts the "<M> already present" integer from a push
// summary line. Mirrors parseUploadedCount's permissive parsing.
func parseAlreadyCount(t *testing.T, line string) int {
	t.Helper()
	const mark = "already present"
	idx := strings.Index(line, mark)
	if idx < 0 {
		t.Fatalf("no %q in push output: %s", mark, line)
	}
	prefix := line[:idx]
	end := len(prefix)
	for end > 0 && prefix[end-1] == ' ' {
		end--
	}
	start := end
	for start > 0 && prefix[start-1] >= '0' && prefix[start-1] <= '9' {
		start--
	}
	if start == end {
		t.Fatalf("could not parse already-present count from %q", line)
	}
	n := 0
	for i := start; i < end; i++ {
		n = n*10 + int(prefix[i]-'0')
	}
	return n
}

// keep sync import used (countingHandler.heads/puts/posts could be guarded by
// a sync mutex; we use atomic instead, but sync remains for future-proofing
// of the test wiring).
var _ sync.Mutex

// encodingCountingHandler wraps an http.Handler and tallies the
// Content-Encoding values seen on chunk PUTs, so a push test can assert the
// compressed-wire path is actually exercised end-to-end.
type encodingCountingHandler struct {
	inner    http.Handler
	zstdPUTs int32
	rawPUTs  int32
}

func newEncodingCountingHandler(inner http.Handler) *encodingCountingHandler {
	return &encodingCountingHandler{inner: inner}
}

func (h *encodingCountingHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPut && isChunkPath(r.URL.Path) {
		switch r.Header.Get("Content-Encoding") {
		case "zstd":
			atomic.AddInt32(&h.zstdPUTs, 1)
		case "":
			atomic.AddInt32(&h.rawPUTs, 1)
		}
	}
	h.inner.ServeHTTP(w, r)
}

// TestCmdPush_UploadsCompressedChunksEndToEnd builds a fixture with a large
// compressible layer (so the LocalStore stores it zstd, above the 4096-byte
// threshold), pushes it, and asserts at least one chunk PUT carried
// Content-Encoding: zstd — i.e. the push used the stored-compressed wire form
// instead of re-expanding the chunk to raw bytes for the upload.
func TestCmdPush_UploadsCompressedChunksEndToEnd(t *testing.T) {
	const ref = "compresspush:v1"
	// ~12 KiB of highly compressible content → one chunk well over the
	// 4096-byte zstd threshold, stored compressed on disk.
	content := bytes.Repeat([]byte("compressible layer payload "), 500)
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)

	root := t.TempDir()
	if err := runIngest(Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}},
		root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	regStore := newRegistryStore(t)
	regSrv, err := registry.NewServer(regStore, filepath.Join(t.TempDir(), "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	regSrv.SetLogger(log.New(io.Discard, "", 0))
	ech := newEncodingCountingHandler(regSrv.Handler())
	ts := httptest.NewServer(ech)
	t.Cleanup(ts.Close)

	var out bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}},
		[]string{"-registry", ts.URL, ref}); err != nil {
		t.Fatalf("cmdPush: %v", err)
	}
	if got := atomic.LoadInt32(&ech.zstdPUTs); got == 0 {
		t.Errorf("expected at least one zstd-encoded chunk PUT, saw 0 (rawPUTs=%d): %s", ech.rawPUTs, out.String())
	}
}
