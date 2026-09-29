package main

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	voilapb "voila/internal/proto"
	"voila/internal/registry"

	"google.golang.org/protobuf/proto"
)

// startTestRegistry spins an httptest-backed registry.Server over a fresh
// rootA LocalStore + images dir, returns the URL of the running server. The
// returned cleanup closes the server + the local store.
func startTestRegistry(t *testing.T) (url string, rootReg string, cleanup func()) {
	t.Helper()
	rootReg = t.TempDir()
	store, err := chunkstore.OpenLocal(rootReg)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	srv, err := registry.NewServer(store, filepath.Join(rootReg, "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	srv.SetLogger(log.New(io.Discard, "", 0))
	ts := httptest.NewServer(srv.Handler())
	cleanup = func() {
		ts.Close()
		_ = store.Close()
	}
	t.Cleanup(cleanup)
	return ts.URL, rootReg, cleanup
}

// countChunksFiles is shared with cmd_daemon_test.go (same package) — it
// walks <root>/chunks and counts regular files. Re-declared inline is not
// allowed (Go rejects duplicates in the same package), so we use it from the
// already-defined helper.

// assertZeroChunks fails t if any chunks live under <root>/chunks.
func assertZeroChunks(t *testing.T, root string) {
	t.Helper()
	if n := countChunksFiles(t, root); n != 0 {
		t.Fatalf("expected 0 chunks under %s, got %d", root, n)
	}
}

// pullRowForRef opens root's image store and returns the row for ref, or fatals.
func pullRowForRef(t *testing.T, root, ref string) imagestore.Record {
	t.Helper()
	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("openImageStore: %v", err)
	}
	defer store.Close()
	rows, err := store.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	for _, r := range rows {
		if r.Ref == ref {
			return r
		}
	}
	t.Fatalf("no image row for ref %q in %s", ref, root)
	return imagestore.Record{}
}

// TestCmdPushPull_Integration ingests a tiny fixture into rootA, pushes it
// to an httptest registry, pulls the manifest into a fresh rootB, and
// asserts:
//   - rootB has the .pb manifest file
//   - rootB's images.db has a row for the ref with the right totals
//   - rootB has ZERO chunks (lazy is the point)
//   - a CachedStore.Get on rootB for the config chunk succeeds AND caches
//     the chunk locally afterward (write-through).
func TestCmdPushPull_Integration(t *testing.T) {
	url, _, _ := startTestRegistry(t)
	ctx := context.Background()

	// 1. Ingest into rootA.
	content := []byte("push pull fixture body")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	rootA := t.TempDir()
	const ref = "remotetest:v1"
	ingestCfg := Config{Root: rootA, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(ingestCfg, rootA, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	// 2. Push from rootA to the test registry.
	var pushOut bytes.Buffer
	pushCfg := Config{Root: rootA, Stdout: &pushOut, Stderr: &bytes.Buffer{}}
	if err := cmdPush(pushCfg, []string{"-registry", url, ref}); err != nil {
		t.Fatalf("cmdPush: %v", err)
	}
	pushSummary := pushOut.String()
	if !strings.Contains(pushSummary, "pushed "+ref) {
		t.Errorf("push output should start with \"pushed %s\":\n%s", ref, pushSummary)
	}
	if !strings.Contains(pushSummary, "chunks uploaded") || !strings.Contains(pushSummary, "already present") {
		t.Errorf("push output missing chunk counts:\n%s", pushSummary)
	}

	// 3. Pull from the registry into a fresh rootB.
	rootB := t.TempDir()
	var pullOut bytes.Buffer
	pullCfg := Config{Root: rootB, Stdout: &pullOut, Stderr: &bytes.Buffer{}}
	if err := cmdPull(pullCfg, []string{"-registry", url, ref}); err != nil {
		t.Fatalf("cmdPull: %v", err)
	}
	if !strings.Contains(pullOut.String(), "pulled "+ref) ||
		!strings.Contains(pullOut.String(), "manifest only") ||
		!strings.Contains(pullOut.String(), "chunks stream on demand") {
		t.Errorf("pull output malformed: %q", pullOut.String())
	}
	// Manifest file present.
	pbPath := filepath.Join(rootB, "images", imagestore.RefKey(ref)+".pb")
	if _, err := os.Stat(pbPath); err != nil {
		t.Fatalf("pulled manifest file %q missing: %v", pbPath, err)
	}
	pbBytes, err := os.ReadFile(pbPath)
	if err != nil {
		t.Fatal(err)
	}
	var im voilapb.ImageManifest
	if err := proto.Unmarshal(pbBytes, &im); err != nil {
		t.Fatalf("unmarshal pulled manifest: %v", err)
	}
	if im.GetImageRef() != ref {
		t.Errorf("pulled image_ref = %q, want %q", im.GetImageRef(), ref)
	}

	// 4. Assert zero chunks on disk in rootB (lazy).
	assertZeroChunks(t, rootB)

	// 5. Row present in rootB's images.db with the right totals.
	row := pullRowForRef(t, rootB, ref)
	if row.ChunkCount != int64(im.GetChunkCount()) {
		t.Errorf("pulled row chunk_count = %d, want %d (from manifest)", row.ChunkCount, im.GetChunkCount())
	}
	if row.TotalSize != int64(im.GetTotalSize()) {
		t.Errorf("pulled row total_size = %d, want %d (from manifest)", row.TotalSize, im.GetTotalSize())
	}

	// 6. CachedStore.Get on rootB for the config chunk → fetch from the
	//    registry + write-through (so a second Get is a local hit).
	localB, err := chunkstore.OpenLocal(rootB)
	if err != nil {
		t.Fatalf("OpenLocal rootB: %v", err)
	}
	defer localB.Close()
	client, err := registry.NewClient(url)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	cached := chunkstore.NewCached(localB, client)
	var cfgID chunkstore.ChunkID
	copy(cfgID[:], im.GetConfigChunk())
	got, err := cached.Get(ctx, cfgID)
	if err != nil {
		t.Fatalf("CachedStore.Get(config chunk): %v", err)
	}
	// Sanity: the chunk is now on disk (write-through).
	if _, ok := localB.Stat(cfgID); !ok {
		t.Fatal("config chunk not cached locally after CachedStore.Get")
	}
	// Second Get is a pure local hit; the remote fetcher is no longer
	// consulted because the local store serves the request directly.
	got2, err := cached.Get(ctx, cfgID)
	if err != nil {
		t.Fatalf("second CachedStore.Get: %v", err)
	}
	if !bytes.Equal(got, got2) {
		t.Fatalf("second Get returned different bytes (len %d vs %d)", len(got), len(got2))
	}
}

// TestCmdPush_RegistryRequired verifies push and pull error clearly when no
// registry URL is configured (no -registry flag, no $VOILA_REGISTRY env).
func TestCmdPush_RegistryRequired(t *testing.T) {
	// Strip the env var so resolveRegistry returns "".
	t.Setenv("VOILA_REGISTRY", "")
	root := t.TempDir()
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := cmdPush(cfg, []string{"x:v1"}); err == nil ||
		!strings.Contains(err.Error(), "voila login") {
		t.Errorf("push without registry: err = %v, want voila login hint", err)
	}
	if err := cmdPull(cfg, []string{"x:v1"}); err == nil ||
		!strings.Contains(err.Error(), "voila login") {
		t.Errorf("pull without registry: err = %v, want voila login hint", err)
	}
}

// TestCmdPush_ConcurrencyFlagRespected verifies the -concurrency flag is
// honored (and clamped): a push with -concurrency 1 succeeds against a real
// registry. The env-var path is covered by resolvePushConcurrency's logic;
// here we exercise the flag wiring end-to-end.
func TestCmdPush_ConcurrencyFlagRespected(t *testing.T) {
	url, _, _ := startTestRegistry(t)
	content := []byte("concurrency flag fixture")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	root := t.TempDir()
	const ref = "conc:v1"
	if err := runIngest(Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}},
		root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}
	var out bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}},
		[]string{"-registry", url, "-concurrency", "1", ref}); err != nil {
		t.Fatalf("cmdPush -concurrency 1: %v", err)
	}
	if !strings.HasPrefix(out.String(), "pushed "+ref+": ") {
		t.Fatalf("push summary shape wrong: %q", out.String())
	}
}

// TestResolvePushConcurrency covers the flag / env / clamp precedence: the
// flag wins when set explicitly; otherwise $VOILA_PUSH_CONCURRENCY is honored;
// out-of-range values are clamped to [1, 1024].
func TestResolvePushConcurrency(t *testing.T) {
	// Flag set explicitly (non-default) wins.
	if got := resolvePushConcurrency(4); got != 4 {
		t.Errorf("resolvePushConcurrency(4) = %d, want 4", got)
	}
	// Flag at default + env set → env wins.
	t.Setenv("VOILA_PUSH_CONCURRENCY", "17")
	if got := resolvePushConcurrency(defaultPushConcurrency); got != 17 {
		t.Errorf("env path: resolvePushConcurrency(default) = %d, want 17", got)
	}
	// Flag at default + bad env → default.
	t.Setenv("VOILA_PUSH_CONCURRENCY", "not-a-number")
	if got := resolvePushConcurrency(defaultPushConcurrency); got != defaultPushConcurrency {
		t.Errorf("bad env: resolvePushConcurrency(default) = %d, want %d", got, defaultPushConcurrency)
	}
	// Clamp: below min → min.
	if got := resolvePushConcurrency(0); got != minPushConcurrency {
		t.Errorf("resolvePushConcurrency(0) = %d, want %d", got, minPushConcurrency)
	}
	// Clamp: above max → max.
	if got := resolvePushConcurrency(100000); got != maxPushConcurrency {
		t.Errorf("resolvePushConcurrency(100000) = %d, want %d", got, maxPushConcurrency)
	}
}

// TestCmdPush_IdempotentRePush pushes the same image twice and verifies the
// second push reports zero chunks uploaded (every chunk was already
// present), exercising the HEAD-before-PUT path against a real server.
func TestCmdPush_IdempotentRePush(t *testing.T) {
	url, _, _ := startTestRegistry(t)
	content := []byte("idempotent push")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	root := t.TempDir()
	const ref = "idempotent:v1"
	if err := runIngest(Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}},
		root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}
	// First push uploads everything.
	var first bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &first, Stderr: &bytes.Buffer{}},
		[]string{"-registry", url, ref}); err != nil {
		t.Fatalf("first push: %v", err)
	}
	if !strings.Contains(first.String(), "chunks uploaded") {
		t.Fatalf("first push output malformed:\n%s", first.String())
	}
	// Extract the "N chunks uploaded" count from the first push.
	firstUploaded := parseUploadedCount(t, first.String())
	if firstUploaded == 0 {
		t.Fatalf("first push uploaded 0 chunks; fixture must be non-empty: %s", first.String())
	}
	// Second push: every chunk already present → 0 uploaded, all M "already
	// present".
	var second bytes.Buffer
	if err := cmdPush(Config{Root: root, Stdout: &second, Stderr: &bytes.Buffer{}},
		[]string{"-registry", url, ref}); err != nil {
		t.Fatalf("second push: %v", err)
	}
	if got := parseUploadedCount(t, second.String()); got != 0 {
		t.Errorf("second push uploaded %d chunks, want 0 (idempotent): %s", got, second.String())
	}
}

// parseUploadedCount extracts the "N chunks uploaded" integer from a push
// summary line. It is permissive about whitespace and accepts the exact
// format cmdPush prints ("pushed <ref>: N chunks uploaded, M already
// present, X MiB").
func parseUploadedCount(t *testing.T, line string) int {
	t.Helper()
	mark := "chunks uploaded"
	idx := strings.Index(line, mark)
	if idx < 0 {
		t.Fatalf("no %q in push output: %s", mark, line)
	}
	prefix := line[:idx]
	// Walk back to the leading integer.
	end := len(prefix)
	for end > 0 && (prefix[end-1] == ' ') {
		end--
	}
	start := end
	for start > 0 && prefix[start-1] >= '0' && prefix[start-1] <= '9' {
		start--
	}
	if start == end {
		t.Fatalf("could not parse uploaded count from %q", line)
	}
	var n int
	for i := start; i < end; i++ {
		n = n*10 + int(prefix[i]-'0')
	}
	return n
}
