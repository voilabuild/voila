package main

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/imagestore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// ----- minimal OCI-layout tarball builder (inline; ingest test helpers are
// unexported in package ingest, so we recreate a tiny version here). -----

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// buildTinyOCITar builds an OCI-layout tarball in memory containing:
//   - oci-layout
//   - index.json (single manifest entry, single platform)
//   - blobs/sha256/<manifest>      (image manifest JSON)
//   - blobs/sha256/<config>        (config JSON)
//   - blobs/sha256/<layer>         (uncompressed layer tar)
//
// The layer contains a single regular file "hello.txt" with the given content.
func buildTinyOCITar(t *testing.T, content []byte) []byte {
	t.Helper()

	// Layer tar: one regular file.
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

// TestRunIngest_Smoke exercises the full factored ingest command body against
// a tiny synthetic OCI-layout tarball and verifies persistence + summary.
func TestRunIngest_Smoke(t *testing.T) {
	content := []byte("hello voila world")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)

	root := t.TempDir()
	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &out}

	const refOverride = "test:v1"
	if err := runIngest(cfg, root, tarball, refOverride, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	summary := out.String()
	for _, want := range []string{"ingest summary", refOverride, "bytes in", "chunks stored"} {
		if !strings.Contains(summary, want) {
			t.Errorf("summary missing %q:\n%s", want, summary)
		}
	}

	// The ImageManifest protobuf file must exist under <root>/images/<key>.pb.
	entries, err := os.ReadDir(filepath.Join(root, "images"))
	if err != nil {
		t.Fatalf("read images dir: %v", err)
	}
	var pbFile string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".pb") {
			pbFile = e.Name()
			break
		}
	}
	if pbFile == "" {
		t.Fatalf("no .pb manifest written under images/; entries=%v", entries)
	}
	if !strings.HasPrefix(pbFile, "test_v1-") {
		t.Errorf("pb filename %q should start with sanitized ref \"test_v1-\"", pbFile)
	}

	pbBytes, err := os.ReadFile(filepath.Join(root, "images", pbFile))
	if err != nil {
		t.Fatal(err)
	}
	var im voilapb.ImageManifest
	if err := proto.Unmarshal(pbBytes, &im); err != nil {
		t.Fatalf("unmarshal image manifest: %v", err)
	}
	if im.GetImageRef() != refOverride {
		t.Errorf("image_ref = %q, want %q", im.GetImageRef(), refOverride)
	}
	if len(im.GetMergedRootManifestChunk()) != 32 {
		t.Errorf("merged root manifest chunk len = %d, want 32", len(im.GetMergedRootManifestChunk()))
	}
	if len(im.GetConfigChunk()) != 32 {
		t.Errorf("config chunk len = %d, want 32", len(im.GetConfigChunk()))
	}
	if len(im.GetProvenanceLayers()) != 1 {
		t.Errorf("provenance layers = %d, want 1", len(im.GetProvenanceLayers()))
	}

	// The sqlite db should have one row with ref == override.
	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("images db rows = %d, want 1", len(rows))
	}
	if rows[0].Ref != refOverride {
		t.Errorf("db ref = %q, want %q", rows[0].Ref, refOverride)
	}
	if rows[0].TotalSize != int64(len(content)) {
		t.Errorf("db total_size = %d, want %d", rows[0].TotalSize, len(content))
	}
	if rows[0].ChunkCount != 1 {
		t.Errorf("db chunk_count = %d, want 1", rows[0].ChunkCount)
	}
	_ = store.Close()

	// `voila images` should list the row, via the cmdImages entry point.
	var imgOut bytes.Buffer
	imgCfg := Config{Root: root, Stdout: &imgOut, Stderr: &imgOut}
	if err := cmdImages(imgCfg, nil); err != nil {
		t.Fatalf("cmdImages: %v", err)
	}
	if !strings.Contains(imgOut.String(), refOverride) {
		t.Errorf("voila images output missing ref %q:\n%s", refOverride, imgOut.String())
	}

	// Re-ingest should UPSERT (still one row, same pb filename) rather than
	// insert a duplicate. It must also HIT the per-layer cache (the cmd path
	// wires imageStore as Options.LayerCache) so LayersReused > 0 — surface
	// via the "layers reused:" summary line. The first ingest misses the
	// cache (LayersReused=0); the re-ingest hits → "layers reused: 1/1".
	var reOut bytes.Buffer
	reCfg := Config{Root: root, Stdout: &reOut, Stderr: &reOut}
	if err := runIngest(reCfg, root, tarball, refOverride, "linux/amd64"); err != nil {
		t.Fatalf("re-runIngest: %v", err)
	}
	reSummary := reOut.String()
	if !strings.Contains(reSummary, "layers reused:") {
		t.Errorf("re-ingest summary missing 'layers reused:' line:\n%s", reSummary)
	}
	if !strings.Contains(reSummary, "layers reused:   1/1") {
		t.Errorf("re-ingest summary should report LayersReused=1/1:\n%s", reSummary)
	}
	store2, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	rows2, err := store2.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows2) != 1 {
		t.Errorf("after re-ingest rows = %d, want 1 (upsert)", len(rows2))
	}
	// The layers table should have one row keyed by the single layer's OCI
	// digest; the cache survives across ingests and is consulted for hits.
	layerRows, err := store2.CountLayerCacheRows()
	if err != nil {
		t.Fatalf("count layers: %v", err)
	}
	if layerRows != 1 {
		t.Errorf("layers table rows = %d, want 1 (single OCI layer cached)", layerRows)
	}
	_ = store2.Close()
}

// TestRunIngest_MissingTarball ensures a clear non-panic error for a missing
// tarball path.
func TestRunIngest_MissingTarball(t *testing.T) {
	cfg := Config{Root: t.TempDir(), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	err := runIngest(cfg, cfg.Root, filepath.Join(cfg.Root, "nope.tar"), "", "")
	if err == nil {
		t.Fatal("expected error for missing tarball, got nil")
	}
	if !strings.Contains(err.Error(), "stat tarball") {
		t.Errorf("error should mention tarball stat: %v", err)
	}
}

// TestRun_UnknownAndNoArgs verifies that no-args and an unknown subcommand
// yield exit code 2 from run() with a usage/unknown message on stderr.
func TestRun_UnknownAndNoArgs(t *testing.T) {
	if got := run(nil); got != 2 {
		t.Errorf("run(nil) = %d, want 2", got)
	}

	stderr := captureStderr(func() int { return run([]string{"nope"}) })
	if !strings.Contains(stderr, "unknown command") {
		t.Errorf("stderr should mention unknown command: %q", stderr)
	}
}

// captureStderr runs fn with os.Stderr redirected to a pipe and returns the
// captured text. run() writes to os.Stderr by construction.
func captureStderr(fn func() int) string {
	old := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w
	_ = fn()
	w.Close()
	os.Stderr = old

	var buf bytes.Buffer
	tmp := make([]byte, 4096)
	for {
		n, err := r.Read(tmp)
		buf.Write(tmp[:n])
		if err != nil {
			break
		}
	}
	return buf.String()
}

// keep imports used.
var _ = context.Background
