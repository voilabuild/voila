package ingest

import (
	"archive/tar"
	"bytes"
	"context"
	"fmt"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// sha256Hex and writeTempTarball are shared with phase_b_test.go (same
// package), so they are not redefined here.
var _ = sha256Hex
var _ = writeTempTarball

// buildTinyOCITar builds the same shape of OCI-layout tarball the cmd tests
// use: one config, one manifest, one uncompressed layer tar with a single
// regular file holding content.
func buildTinyOCITar(t *testing.T, content []byte, ref string) []byte {
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
	manifestHex := sha256Hex([]byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		configHex, len(configJSON), layerHex, len(layer))))
	manifestJSON := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		configHex, len(configJSON), layerHex, len(layer)))

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
	write("index.json", []byte(`{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:`+manifestHex+`","size":`+fmt.Sprintf("%d", len(manifestJSON))+`}]}`))
	write("blobs/sha256/"+manifestHex, manifestJSON)
	write("blobs/sha256/"+configHex, configJSON)
	write("blobs/sha256/"+layerHex, layer)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// chunkCount returns the number of chunks the store currently indexes by
// asking GC over an empty keep-set. (Not efficient — but only used in tests.)
func chunkCount(t *testing.T, store *chunkstore.LocalStore) int {
	t.Helper()
	removed, err := store.GC(map[chunkstore.ChunkID]struct{}{})
	if err != nil {
		t.Fatalf("count chunks: %v", err)
	}
	return removed
}

// TestReachable_CoversFullIngest ingests a tiny image and asserts that
// Reachable covers every chunk the store holds — i.e. gc right after ingest
// removes nothing. It then adds an extra unreferenced chunk and asserts gc
// removes exactly that chunk, and finally drops the image from the input list
// and asserts the image's own chunks all become unreachable.
func TestReachable_CoversFullIngest(t *testing.T) {
	content := []byte("reachable content here")
	tarBytes := buildTinyOCITar(t, content, "test:v1")
	tarball := writeTempTarball(t, tarBytes)

	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()

	ctx := context.Background()
	res, err := Ingest(ctx, tarball, store, Options{Ref: "test:v1", Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("Ingest: %v", err)
	}

	im := buildTestImageManifest(res)
	images := []*voilapb.ImageManifest{im}

	reachable, err := Reachable(ctx, store, images)
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}

	// Every chunk the store holds must be reachable right after ingest.
	totalChunks := chunkCount(t, store) // nukes the store though!
	if totalChunks == 0 {
		t.Fatalf("expected chunks after ingest, got 0")
	}
	if len(reachable) != totalChunks {
		t.Errorf("reachable size = %d, want %d (full store)", len(reachable), totalChunks)
	}

	// gc must remove zero chunks when the keep set == Reachable.
	// (Re-ingest because the chunkCount helper deleted the store's blobs.)
	if _, err := Ingest(ctx, tarball, store, Options{Ref: "test:v1", Platform: "linux/amd64"}); err != nil {
		t.Fatalf("re-Ingest: %v", err)
	}
	reachable, err = Reachable(ctx, store, images)
	if err != nil {
		t.Fatalf("Reachable (post re-ingest): %v", err)
	}
	removed, err := store.GC(reachable)
	if err != nil {
		t.Fatalf("GC: %v", err)
	}
	if removed != 0 {
		t.Errorf("GC removed %d chunks after fresh ingest, want 0", removed)
	}

	// Adding an unreferenced chunk and re-running gc removes exactly it.
	garbage := []byte("i am garbage, unreferenced by anything")
	garbageID, err := store.Put(garbage)
	if err != nil {
		t.Fatalf("Put garbage: %v", err)
	}
	reachable, err = Reachable(ctx, store, images)
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}
	if _, present := reachable[garbageID]; present {
		t.Errorf("garbage chunk %s should NOT be reachable", garbageID)
	}
	removed, err = store.GC(reachable)
	if err != nil {
		t.Fatalf("GC: %v", err)
	}
	if removed != 1 {
		t.Errorf("GC removed %d chunks, want exactly 1 (the garbage)", removed)
	}
	// The garbage chunk must now be gone.
	if _, ok := store.Stat(garbageID); ok {
		t.Errorf("garbage chunk still present after GC")
	}

	// Dropping the image from the input list makes every chunk unreachable.
	emptyReachable, err := Reachable(ctx, store, nil)
	if err != nil {
		t.Fatalf("Reachable(nil): %v", err)
	}
	if len(emptyReachable) != 0 {
		t.Errorf("Reachable(nil) = %d chunks, want 0", len(emptyReachable))
	}
	removed, err = store.GC(emptyReachable)
	if err != nil {
		t.Fatalf("GC after drop: %v", err)
	}
	if removed == 0 {
		t.Errorf("dropping the image should make its chunks unreachable; GC removed 0")
	}
}

// TestReachable_WalksExternalSubtrees builds a small Manifest that splits into
// an external subtree chunk and asserts Reachable walks into it (i.e. the
// subtree chunk is reachable from the image). We synthesize the manifests by
// hand to deterministically force an external subtree without relying on the
// 64 KiB split threshold.
func TestReachable_WalksExternalSubtrees(t *testing.T) {
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()

	ctx := context.Background()

	// A leaf manifest carrying a File whose Block points at one content chunk.
	contentChunk, err := store.Put([]byte("leaf content"))
	if err != nil {
		t.Fatal(err)
	}
	leafManifest := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 1, Mode: 0o755, Entries: map[string]uint64{"file": 2}}},
		Files: map[uint64]*voilapb.File{
			2: {Inode: 2, Mode: 0o644, Blocks: []*voilapb.Block{{
				OffsetInFile: 0, ChunkId: contentChunk[:], LogicalLen: uint64(len("leaf content")),
			}}},
		},
		ExternalSubtrees: map[uint64][]byte{},
	}
	leafData, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, leafManifest)
	if err != nil {
		t.Fatal(err)
	}
	leafChunk, err := store.Put(leafData)
	if err != nil {
		t.Fatal(err)
	}

	// Root manifest with one entry pointing at the external subtree (inode 2).
	rootManifest := &voilapb.Manifest{
		Dirs:             []*voilapb.Dir{{Inode: 1, Mode: 0o755, Entries: map[string]uint64{"sub": 2}}},
		Files:            map[uint64]*voilapb.File{},
		Symlinks:         map[uint64]*voilapb.Symlink{},
		Devices:          map[uint64]*voilapb.Device{},
		ExternalSubtrees: map[uint64][]byte{2: leafChunk[:]},
	}
	rootData, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, rootManifest)
	if err != nil {
		t.Fatal(err)
	}
	rootChunk, err := store.Put(rootData)
	if err != nil {
		t.Fatal(err)
	}

	configChunk, err := store.Put([]byte(`{"os":"linux"}`))
	if err != nil {
		t.Fatal(err)
	}

	im := &voilapb.ImageManifest{
		ImageRef:                "x:y",
		ConfigChunk:             configChunk[:],
		MergedRootManifestChunk: rootChunk[:],
		ProvenanceLayers:        []*voilapb.Layer{{RootManifestChunk: leafChunk[:]}},
	}

	reachable, err := Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}
	for _, want := range []chunkstore.ChunkID{rootChunk, leafChunk, configChunk, contentChunk} {
		if _, ok := reachable[want]; !ok {
			t.Errorf("expected chunk %s to be reachable; reachable set = %v", want, reachable)
		}
	}

	// gc must remove nothing.
	removed, err := store.GC(reachable)
	if err != nil {
		t.Fatalf("GC: %v", err)
	}
	if removed != 0 {
		t.Errorf("GC removed %d, want 0", removed)
	}
}

// TestReachable_MissingChunkErrors ensures a corrupt store (a manifest chunk
// that has been deleted) makes Reachable return an error, mirroring the spec's
// "do NOT gc on errors" rule.
func TestReachable_MissingChunkErrors(t *testing.T) {
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()

	// Construct an ImageManifest whose root chunk is a fabricated 32-byte id
	// that does not exist anywhere in the store.
	var fakeID chunkstore.ChunkID
	for i := range fakeID {
		fakeID[i] = byte(0xAB)
	}
	im := &voilapb.ImageManifest{
		ImageRef:                "x:y",
		MergedRootManifestChunk: fakeID[:],
	}
	if _, err := Reachable(ctx, store, []*voilapb.ImageManifest{im}); err == nil {
		t.Fatalf("Reachable should error on a missing manifest chunk")
	}
}

func TestClosureStats_NonZeroAfterIngest(t *testing.T) {
	content := []byte("closure stats content")
	tarBytes := buildTinyOCITar(t, content, "test:v1")
	tarball := writeTempTarball(t, tarBytes)

	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctx := context.Background()
	res, err := Ingest(ctx, tarball, store, Options{Ref: "test:v1", Platform: "linux/amd64"})
	if err != nil {
		t.Fatal(err)
	}
	im := buildTestImageManifest(res)

	chunks, bytes, err := ClosureStats(ctx, store, im)
	if err != nil {
		t.Fatal(err)
	}
	if chunks == 0 {
		t.Fatal("expected non-zero chunk count")
	}
	if bytes == 0 {
		t.Fatal("expected non-zero logical bytes")
	}
	reachable, err := Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		t.Fatal(err)
	}
	if chunks != uint64(len(reachable)) {
		t.Fatalf("ClosureStats chunks %d != reachable %d", chunks, len(reachable))
	}
}

// buildTestImageManifest mirrors cmd/voila's buildImageManifest; it is
// duplicated here because cmd/ is not importable from internal/ingest and
// the test only needs a persisted ImageManifest shape.
func buildTestImageManifest(res *Result) *voilapb.ImageManifest {
	layers := make([]*voilapb.Layer, 0, len(res.Layers))
	for _, l := range res.Layers {
		layers = append(layers, &voilapb.Layer{
			RootManifestChunk: l.RootManifestChunk[:],
			WhiteoutsCount:    l.WhiteoutsCount,
		})
	}
	return &voilapb.ImageManifest{
		ImageRef:                res.Ref,
		ImageDigest:             res.ImageDigest,
		ConfigChunk:             res.ConfigChunk[:],
		MergedRootManifestChunk: res.MergedRootManifestChunk[:],
		ProvenanceLayers:        layers,
	}
}

// TestReachable_IgnoresHardlinkEntries builds a per-layer Manifest containing
// a symbolic Hardlink entry (Per-Layer mode) plus a File referencing one
// content chunk, and asserts Reachable walks exactly the manifest + content
// chunks and IGNORES the Hardlink entry (hardlinks reference no chunks). The
// hardlink's target_path may name a file in another layer this ImageManifest
// does not even reference; the reachability walk must not stray into it.
func TestReachable_IgnoresHardlinkEntries(t *testing.T) {
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	contentChunk, err := store.Put([]byte("real content"))
	if err != nil {
		t.Fatal(err)
	}
	// A content chunk that the hardlink's *target path* would point at if we
	// (incorrectly) tried to fetch it — placed in the store to make the test
	// fail loudly if Reachable ever started following hardlinks. If the walk
	// stays correct, this chunk must NOT appear in the reachable set.
	decoyChunk, err := store.Put([]byte("decoy target content"))
	if err != nil {
		t.Fatal(err)
	}
	_ = decoyChunk

	// Per-layer manifest with inode 2 a regular file, inode 3 a symbolic
	// hardlink (Dir entry naming it, no File entry, Hardlinks[3]).
	layerManifest := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 1, Mode: 0o755, Entries: map[string]uint64{
			"file":  2,
			"xlink": 3,
		}}},
		Files: map[uint64]*voilapb.File{
			2: {Inode: 2, Mode: 0o644, Blocks: []*voilapb.Block{{
				OffsetInFile: 0, ChunkId: contentChunk[:], LogicalLen: uint64(len("real content")),
			}}},
		},
		Symlinks:         map[uint64]*voilapb.Symlink{},
		Devices:          map[uint64]*voilapb.Device{},
		ExternalSubtrees: map[uint64][]byte{},
		Hardlinks: map[uint64]*voilapb.Hardlink{
			3: {Inode: 3, TargetPath: "elsewhere/in/another/layer"},
		},
	}
	layerData, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, layerManifest)
	if err != nil {
		t.Fatal(err)
	}
	layerChunk, err := store.Put(layerData)
	if err != nil {
		t.Fatal(err)
	}

	configChunk, err := store.Put([]byte(`{"os":"linux"}`))
	if err != nil {
		t.Fatal(err)
	}

	// Use the SAME store so decoyChunk is present but unreferenced; Reachable
	// must not include it.
	im := &voilapb.ImageManifest{
		ImageRef:                "x:y",
		ConfigChunk:             configChunk[:],
		MergedRootManifestChunk: layerChunk[:],
		ProvenanceLayers:        []*voilapb.Layer{{RootManifestChunk: layerChunk[:]}},
	}

	reachable, err := Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		t.Fatalf("Reachable: %v", err)
	}
	want := []chunkstore.ChunkID{layerChunk, contentChunk, configChunk}
	for _, w := range want {
		if _, ok := reachable[w]; !ok {
			t.Errorf("expected chunk %s to be reachable", w)
		}
	}
	if _, ok := reachable[decoyChunk]; ok {
		t.Errorf("decoy chunk %s (a hardlink target) must NOT be reachable", decoyChunk)
	}
	if extra := len(reachable) - len(want); extra != 0 {
		t.Errorf("reachable set size = %d, want exactly %d (hardlink target leaked?) reachable=%v",
			len(reachable), len(want), reachable)
	}
}
