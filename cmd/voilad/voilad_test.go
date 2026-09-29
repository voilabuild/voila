package main

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
	"voila/internal/registry"
	"voila/internal/worker"
)

// ============================================================================
// mount subcommand: minimal "parses args + errors cleanly on non-linux" test
// ============================================================================

// TestDriftdMount_BadArgCount asserts the mount subcommand parses its
// positional args and returns a clear usage error when the count is wrong.
// This is cross-platform: it does not touch the FUSE daemon; it only
// exercises the flag-set / arg-count validation.
func TestDriftdMount_BadArgCount(t *testing.T) {
	cfg := Config{Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	for _, args := range [][]string{{}, {"only-one-positional"}} {
		err := cmdMount(cfg, args)
		if err == nil {
			t.Errorf("cmdMount(%v) should error on wrong arg count", args)
			continue
		}
		if !strings.Contains(err.Error(), "usage") {
			t.Errorf("cmdMount(%v) err = %v, want a usage-style message", args, err)
		}
	}
}

// TestDriftdNonLinux_Refuses asserts that on a non-Linux host voilad exits with
// the "voilad requires linux" message and code 1, regardless of which
// subcommand was requested. Skipped on Linux where voilad's plumbing actually
// runs. This covers the "compiles everywhere but errors cleanly on
// non-linux" half of the spec.
func TestDriftdNonLinux_Refuses(t *testing.T) {
	if cliGoos == "linux" {
		t.Skip("on linux voilad actually runs; the non-linux refusal test is N/A")
	}
	old := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w
	code := run([]string{"mount", "some-ref", filepath.Join(t.TempDir(), "mp")})
	_ = w.Close()
	os.Stderr = old
	buf, _ := io.ReadAll(r)
	if code != 1 {
		t.Fatalf("run exit code = %d, want 1", code)
	}
	if !strings.Contains(string(buf), "voilad requires linux") {
		t.Errorf("stderr = %q, want \"voilad requires linux\"", string(buf))
	}
}

// ============================================================================
// Resolve closure (makeResolve): auto-pull on miss + digest-prefix skip
// ============================================================================
//
// These tests moved out of cmd/voila so the CLI binary no longer depends on
// internal/worker (task 16's `go list -deps` proof). The daemon is the only
// place the Resolve closure lives now; voilad owns the test.

// startTestRegistry spins an httptest-backed registry.Server over a fresh
// rootReg-backed LocalStore + images dir, returns the URL of the running
// server. The chunk store is closed via t.Cleanup.
func startTestRegistry(t *testing.T) (url string, rootReg string) {
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
	t.Cleanup(func() {
		ts.Close()
		_ = store.Close()
	})
	return ts.URL, rootReg
}

// sha256Hex mirrors the cmd/voila test helper.
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// buildTinyOCITar builds an OCI-layout tarball with one layer file. Mirror of
// the cmd/voila test fixture builder (cross-binary test helpers per task 16's
// "tests live with the binary that owns them" line).
func buildTinyOCITar(t *testing.T, content []byte) []byte {
	t.Helper()

	var layerBuf bytes.Buffer
	lw := tar.NewWriter(&layerBuf)
	if err := lw.WriteHeader(&tar.Header{
		Name: "hello.txt", Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(content)),
	}); err != nil {
		t.Fatal(err)
	}
	lw.Write(content)
	if err := lw.Close(); err != nil {
		t.Fatal(err)
	}
	layer := layerBuf.Bytes()

	configJSON := []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	configHex := sha256Hex(configJSON)
	layerHex := sha256Hex(layer)

	manifestJSON := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		configHex, len(configJSON), layerHex, len(layer)))
	manifestHex := sha256Hex(manifestJSON)

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	write := func(name string, body []byte) {
		if err := tw.WriteHeader(&tar.Header{
			Name: name, Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(body)),
		}); err != nil {
			t.Fatal(err)
		}
		if len(body) > 0 {
			tw.Write(body)
		}
	}
	write("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	indexJSON := []byte(`{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:` + manifestHex + `","size":` + fmt.Sprintf("%d", len(manifestJSON)) + `}]}`)
	write("index.json", indexJSON)
	write("blobs/sha256/"+manifestHex, manifestJSON)
	write("blobs/sha256/"+configHex, configJSON)
	write("blobs/sha256/"+layerHex, layer)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func writeTempTarball(t *testing.T, body []byte) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "image.tar")
	if err := os.WriteFile(p, body, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// ingestFixture ingests a tiny OCI tarball into a fresh root and writes the
// ImageManifest pb + images.db row, mirroring runIngest's persistence but
// without the human-readable summary (we only need the persisted manifest +
// chunks for the resolve / push tests).
func ingestFixture(t *testing.T, root, tarball, ref, platform string) {
	t.Helper()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()

	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("imagestore.Open: %v", err)
	}
	defer imgStore.Close()

	ctx := context.Background()
	res, err := ingest.Ingest(ctx, tarball, store, ingest.Options{
		Platform:   platform,
		Ref:        ref,
		LayerCache: imgStore,
	})
	if err != nil {
		t.Fatalf("ingest.Ingest: %v", err)
	}

	layers := make([]*voilapb.Layer, 0, len(res.Layers))
	for _, l := range res.Layers {
		layers = append(layers, &voilapb.Layer{
			RootManifestChunk: l.RootManifestChunk[:],
			WhiteoutsCount:    l.WhiteoutsCount,
		})
	}
	im := &voilapb.ImageManifest{
		ImageRef:                res.Ref,
		ImageDigest:             res.ImageDigest,
		ConfigChunk:             res.ConfigChunk[:],
		MergedRootManifestChunk: res.MergedRootManifestChunk[:],
		ProvenanceLayers:        layers,
		TotalSize:               res.BytesIn,
		ChunkCount:              res.ChunkCount,
	}
	if err := imgStore.WriteManifestPB(res.Ref, im); err != nil {
		t.Fatalf("WriteManifestPB: %v", err)
	}
	// Upsert a images.db row so Resolve / makeResolve see the totals.
	imageRec := imagestore.Record{
		Ref:                res.Ref,
		ImageDigest:        res.ImageDigest,
		MergedRootManifest: res.MergedRootManifestChunk[:],
		TotalSize:          int64(res.BytesIn),
		ChunkCount:         int64(res.ChunkCount),
		// ingested_ns / last_used_ns omitted — set to current time on Upsert? No;
		// Record.Upsert does NOT auto-fill; leave 0 (consistent with the
		// tests only reading Ref/ImageDigest/ChunkCount/TotalSize).
	}
	if err := imgStore.Upsert(imageRec); err != nil {
		t.Fatalf("Upsert: %v", err)
	}
}

// pushFixtureToRegistry uploads the manifest pb + every reachable chunk from
// root to the registry reachable at url (using the internal/registry client
// directly — voilad ships no `push` subcommand). Mirrors cmd_push.go's bulk
// upload path WITHOUT the bulk-stat negotiation (which is fine for tests:
// the registry starts empty so every chunk is missing).
func pushFixtureToRegistry(t *testing.T, url, root, ref string) {
	t.Helper()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("imagestore.Open: %v", err)
	}
	defer imgStore.Close()
	im, _, err := imagestore.Resolve(imgStore, ref)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	ctx := context.Background()
	reachable, err := ingest.Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}
	client, err := registry.NewClient(url)
	if err != nil {
		t.Fatalf("registry.NewClient: %v", err)
	}
	defer client.Close()
	for id := range reachable {
		data, gerr := store.Get(ctx, id)
		if gerr != nil {
			t.Fatalf("store.Get %s: %v", id, gerr)
		}
		if err := client.PutChunk(ctx, id, data); err != nil {
			t.Fatalf("PutChunk %s: %v", id, err)
		}
	}
	if err := client.PutImageManifest(ctx, ref, im); err != nil {
		t.Fatalf("PutImageManifest: %v", err)
	}
}

// TestResolveClosure_AutoPullOnMiss exercises makeResolve's auto-pull path:
// given a fresh empty rootB + a registry that holds a manifest pushed by
// rootA, a Resolve(query) for the missing ref MUST auto-pull the manifest
// from the registry and resolve successfully (returning the right Ref).
// No chunks are pulled. This is the `voila run <ref>` on an empty root with
// only `$VOILA_REGISTRY` set path, exercised at the resolve-closure level
// without spinning up a daemon.
func TestResolveClosure_AutoPullOnMiss(t *testing.T) {
	url, _ := startTestRegistry(t)
	const ref = "auto:v1"

	rootA := t.TempDir()
	tarBytes := buildTinyOCITar(t, []byte("auto-pull fixture"))
	tarball := writeTempTarball(t, tarBytes)
	ingestFixture(t, rootA, tarball, ref, "linux/amd64")
	pushFixtureToRegistry(t, url, rootA, ref)

	rootB := t.TempDir()
	imgStore, err := imagestore.Open(rootB)
	if err != nil {
		t.Fatalf("imagestore.Open rootB: %v", err)
	}
	defer imgStore.Close()
	storeB, err := chunkstore.OpenLocal(rootB)
	if err != nil {
		t.Fatalf("OpenLocal rootB: %v", err)
	}
	defer storeB.Close()
	hub := worker.NewRegistryHub()
	if err := hub.Configure(url, ""); err != nil {
		t.Fatalf("hub.Configure: %v", err)
	}

	// rootB is empty: a regular imagestore.Resolve MUST report a not-found
	// (sanity check the negative branch — if this passed we'd be testing
	// against a pre-populated root, masking the auto-pull behavior).
	if rows, _ := imgStore.List(); len(rows) != 0 {
		t.Fatalf("rootB pre-condition violated: images.db has %d rows", len(rows))
	}

	// Deliberately pass the raw local store so a regression where resolution
	// starts fetching via Stat would surface as a chunk count >0.
	resolve := makeResolve(imgStore, storeB, hub)
	resolved, err := resolve(ref)
	if err != nil {
		t.Fatalf("auto-pull resolve: %v", err)
	}
	if resolved.Ref != ref {
		t.Errorf("resolved.Ref = %q, want %q", resolved.Ref, ref)
	}
	// Sanity: rootB now has the manifest row (auto-pull persists it).
	store2, _ := imagestore.Open(rootB)
	defer store2.Close()
	rows, _ := store2.List()
	var found bool
	for _, r := range rows {
		if r.Ref == ref {
			found = true
			if r.ChunkCount == 0 {
				t.Error("auto-pull row chunk_count is 0 (should be from manifest)")
			}
		}
	}
	if !found {
		t.Fatal("auto-pull did not persist the images.db row in rootB")
	}
	// Sanity: zero chunks pulled (auto-pull is manifest-only).
	if n := countChunksFiles(t, rootB); n != 0 {
		t.Errorf("auto-pull should NOT fetch chunks, found %d under %s/chunks", n, rootB)
	}
	// The resolved chunk ids must NOT be Stat-able from rootB's local store
	// (the chunks live on the registry; resolve must NOT cache them — that
	// is what the CachedStore wrapper downstream does, not Resolve).
	if _, ok := storeB.Stat(resolved.ConfigChunk); ok {
		t.Error("config chunk was Stat-able in empty rootB; resolve must NOT cache chunks")
	}
	if _, ok := storeB.Stat(resolved.RootChunk); ok {
		t.Error("root chunk was Stat-able in empty rootB; resolve must NOT cache chunks")
	}
}

// TestResolveClosure_AutoPullDigestPrefixDoesNotFetch asserts the heuristic
// in imagestore.AutoPull: a query that looks like a digest prefix (no ':' or
// '/') does NOT trigger a network round-trip. The resolve closure falls
// through to imagestore.Resolve's miss error rather than attempting a
// registry lookup.
func TestResolveClosure_AutoPullDigestPrefixDoesNotFetch(t *testing.T) {
	url, _ := startTestRegistry(t)

	rootB := t.TempDir()
	imgStore, _ := imagestore.Open(rootB)
	defer imgStore.Close()
	storeB, err := chunkstore.OpenLocal(rootB)
	if err != nil {
		t.Fatal(err)
	}
	defer storeB.Close()
	hub := worker.NewRegistryHub()
	if err := hub.Configure(url, ""); err != nil {
		t.Fatal(err)
	}

	resolve := makeResolve(imgStore, storeB, hub)
	if _, err := resolve("deadbeef"); err == nil {
		t.Fatal("resolved a digest-prefix query on an empty root; auto-pull should not have fired")
	} else if !strings.Contains(err.Error(), "no image matching") {
		t.Errorf("digest-prefix resolve should report the standard not-found error, got: %v", err)
	}
}

// countChunksFiles counts the regular files under <root>/chunks recursively.
// (Mirror of cmd/voila's same-named helper.)
func countChunksFiles(t *testing.T, root string) int {
	t.Helper()
	var n int
	dir := filepath.Join(root, "chunks")
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.Mode().IsRegular() {
			n++
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk chunks dir: %v", err)
	}
	return n
}

// ============================================================================
// socket permissions: voilad locks the worker socket to 0600 by default so
// only the owning user can drive it. A system daemon driven by non-root users
// (the install.sh systemd unit) sets VOILA_SOCKET_MODE (e.g. 0660) and
// VOILA_SOCKET_GROUP so group members can dial it. These tests run the real
// voilad binary as a subprocess and stat the socket it creates.
// ============================================================================

// voiladBinary builds the voilad binary once per test process and returns its
// path. Subprocess startup is the only way to exercise the socket-perm code
// path (it runs in main, not a callable function).
func voiladBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "voilad")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = "."
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build voilad: %v\n%s", err, out)
	}
	return bin
}

// startDriftd runs voilad with the given env + args, waits for the socket file
// to appear (polls up to 3s), and returns the process + socket path. The
// caller kills the process.
func startDriftd(t *testing.T, bin, root, sock string, env []string) *exec.Cmd {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(sock), 0o755); err != nil {
		t.Fatalf("mkdir socket dir: %v", err)
	}
	cmd := exec.Command(bin, "-root", root, "-socket", sock)
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatalf("start voilad: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if info, err := os.Stat(sock); err == nil && info.Mode().Type()&os.ModeSocket != 0 {
			return cmd
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	t.Fatalf("voilad did not create socket %s", sock)
	return nil
}

// TestDriftdSocketMode_Default asserts the daemon locks the socket to 0600
// when no VOILA_SOCKET_* env is set (the secure default / back-compat).
func TestDriftdSocketMode_Default(t *testing.T) {
	if cliGoos != "linux" {
		t.Skip("socket mode test requires linux")
	}
	root := t.TempDir()
	sock := filepath.Join(t.TempDir(), "voila.sock")
	cmd := startDriftd(t, voiladBinary(t), root, sock, nil)
	defer cmd.Process.Kill()

	info, err := os.Stat(sock)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := info.Mode() & 0o777; got != 0o600 {
		t.Fatalf("socket mode = %o, want 0600", got)
	}
}

// TestDriftdSocketMode_EnvOverride asserts VOILA_SOCKET_MODE widens the perms
// so a group can dial the socket (the install.sh systemd unit sets 0660).
func TestDriftdSocketMode_EnvOverride(t *testing.T) {
	if cliGoos != "linux" {
		t.Skip("socket mode test requires linux")
	}
	root := t.TempDir()
	sock := filepath.Join(t.TempDir(), "voila.sock")
	cmd := startDriftd(t, voiladBinary(t), root, sock, []string{"VOILA_SOCKET_MODE=0660"})
	defer cmd.Process.Kill()

	info, err := os.Stat(sock)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if got := info.Mode() & 0o777; got != 0o660 {
		t.Fatalf("socket mode = %o, want 0660", got)
	}
}
