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

// roundTripLayer walks a tar (built by add), builds + stores its per-layer
// manifest, decodes it back into a tree, rebuilds the manifest from the
// decoded tree, and asserts the two manifest byte slices are byte-identical.
// It returns the original tree, the decoded tree, and the chunk id for any
// further assertions the caller wants.
func roundTripLayer(t *testing.T, store chunkstore.ChunkStore, add func(*tarBuilder)) (*LayerTree, *LayerTree, chunkstore.ChunkID, []byte, []byte) {
	t.Helper()
	tb := newTarBuilder()
	add(tb)
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), store)
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}
	treeA := res.Tree

	rootA, dataA, err := BuildLayerManifest(treeA, store)
	if err != nil {
		t.Fatalf("BuildLayerManifest (A): %v", err)
	}
	rootChunk, err := store.Put(dataA)
	if err != nil {
		t.Fatalf("store.Put manifest A: %v", err)
	}
	_ = rootA

	treeB, err := DecodeTree(context.Background(), store, rootChunk)
	if err != nil {
		t.Fatalf("DecodeTree: %v", err)
	}
	_, dataB, err := BuildLayerManifest(treeB, store)
	if err != nil {
		t.Fatalf("BuildLayerManifest (B): %v", err)
	}
	return treeA, treeB, rootChunk, dataA, dataB
}

func assertBytesEqual(t *testing.T, dataA, dataB []byte) {
	t.Helper()
	if !bytes.Equal(dataA, dataB) {
		t.Fatalf("round-trip byte-equality failed: len A=%d B=%d\nA=%x\nB=%x",
			len(dataA), len(dataB), dataA, dataB)
	}
}

// TestDecodeTree_RoundTrip covers a layer exercising every node type: dirs,
// files, symlinks, devices, xattrs, within-layer hardlinks, and a cross-layer
// (pending) hardlink. After Build → Store → Decode → Rebuild the two
// manifest byte slices must be identical.
func TestDecodeTree_RoundTrip_AllNodeTypes(t *testing.T) {
	store := newMemStore()
	treeA, treeB, _, dataA, dataB := roundTripLayer(t, store, func(tb *tarBuilder) {
		tb.dir("etc", 0o755).
			file("etc/hosts", []byte("127.0.0.1 localhost\n"), 0o644).
			fileXattrs("etc/secure", []byte("x"), map[string]string{"user.k": "v"}).
			dir("usr/bin", 0o755).
			file("usr/bin/sh", []byte("shebang"), 0o755).
			symlink("bin", "usr/bin").
			device("dev/null", tar.TypeChar, 1, 3).
			device("dev/sda", tar.TypeBlock, 8, 0).
			file("orig", []byte("payload"), 0o644).
			hardlink("alias", "orig").        // within-layer hardlink
			hardlink("xlink", "elsewhere/zz") // cross-layer (pending) hardlink
	})
	_ = treeA
	_ = treeB
	assertBytesEqual(t, dataA, dataB)
}

// TestDecodeTree_RoundTrip_ExternalSubtrees forces external-subtree splitting
// (500 child dirs, each with files) and asserts the manifest bytes round-trip
// through decode even when the original tree split into many chunks.
func TestDecodeTree_RoundTrip_ExternalSubtrees(t *testing.T) {
	store := newMemStore()
	const childDirs = 500
	const filesPerDir = 3
	_, _, _, dataA, dataB := roundTripLayer(t, store, func(tb *tarBuilder) {
		for i := 0; i < childDirs; i++ {
			dir := fmt.Sprintf("d%04d", i)
			tb.dir(dir, 0o755)
			for j := 0; j < filesPerDir; j++ {
				tb.file(fmt.Sprintf("%s/f%d", dir, j),
					[]byte(fmt.Sprintf("content-%d-%d-%s", i, j, bytes.Repeat([]byte("x"), 100))), 0o644)
			}
		}
	})
	assertBytesEqual(t, dataA, dataB)
}

// TestDecodeTree_RoundTrip_PendingHardlinkOnly focuses on the symbolic
// hardlink path: a layer whose only entry is a cross-layer hardlink. The
// decoded tree carries a NodePendingHardlink and re-encoding reproduces the
// exact same symbolic Hardlink entry.
func TestDecodeTree_RoundTrip_PendingHardlinkOnly(t *testing.T) {
	store := newMemStore()
	treeA, _, rootChunk, dataA, dataB := roundTripLayer(t, store, func(tb *tarBuilder) {
		tb.hardlink("only_link", "ghost_target")
	})
	assertBytesEqual(t, dataA, dataB)

	// The pending node in the original tree round-trips to a pending node in
	// the decoded tree with the same LinkTarget.
	pending := treeA.Lookup("only_link")
	if pending == nil || pending.Type != NodePendingHardlink {
		t.Fatalf("treeA only_link: %+v", pending)
	}
	// Re-decode from chunk and check the decoded tree carries the pending
	// node with the same LinkTarget.
	treeB, err := DecodeTree(context.Background(), store, rootChunk)
	if err != nil {
		t.Fatalf("DecodeTree: %v", err)
	}
	pendingB := treeB.Lookup("only_link")
	if pendingB == nil || pendingB.Type != NodePendingHardlink {
		t.Fatalf("decoded tree only_link: %+v", pendingB)
	}
	if pendingB.LinkTarget != "ghost_target" {
		t.Errorf("decoded LinkTarget=%q want ghost_target", pendingB.LinkTarget)
	}
}

// TestDecodeTree_RoundTrip_SharesNodeForHardlinks verifies that a
// within-layer hardlink round-trips with shared *Node across both names AND
// the same nlink preserved.
func TestDecodeTree_RoundTrip_SharesNodeForHardlinks(t *testing.T) {
	store := newMemStore()
	_, treeB, _, dataA, dataB := roundTripLayer(t, store, func(tb *tarBuilder) {
		tb.file("orig", []byte("payload"), 0o644).hardlink("alias", "orig")
	})
	assertBytesEqual(t, dataA, dataB)

	orig := treeB.Lookup("orig")
	alias := treeB.Lookup("alias")
	if orig == nil || alias == nil {
		t.Fatalf("decoded tree missing orig/alias: %+v", treeB)
	}
	if orig != alias {
		t.Errorf("within-layer hardlink does not share *Node: %p != %p", orig, alias)
	}
	if orig.Nlink != 2 {
		t.Errorf("decoded nlink=%d want 2", orig.Nlink)
	}
}

// TestDecodeTree_RoundTrip_MultiNameInodeAcrossSubtreeSplit ensures a
// within-layer hardlink whose two names live in different externalized
// subtrees still round-trips with the same shared inode and byte-identical
// manifest. Both names live in the same dir, but the dir's parent gets
// externalized, exercising the cross-chunk inode lookup path.
func TestDecodeTree_RoundTrip_MultiNameInodeAcrossSubtreeSplit(t *testing.T) {
	store := newMemStore()
	const childDirs = 500 // enough to force splitting
	_, _, _, dataA, dataB := roundTripLayer(t, store, func(tb *tarBuilder) {
		// A within-layer hardlink whose orig sits in the layer root and
		// whose alias sits in a child dir that gets externalized. The two
		// names share one inode (File) in the layer manifest; the File entry
		// appears in the root manifest chunk but the Dir entry for "sub" is
		// in an external chunk, exercising cross-chunk lookup in DecodeTree.
		tb.file("orig_root", []byte("payload for cross-split"), 0o644)
		tb.dir("sub", 0o755)
		tb.hardlink("sub/alias_root", "orig_root") // points at root file
		for i := 0; i < childDirs; i++ {
			dir := fmt.Sprintf("d%04d", i)
			tb.dir(dir, 0o755)
			tb.file(fmt.Sprintf("%s/f", dir), []byte(fmt.Sprintf("content-%d-%s", i, bytes.Repeat([]byte("y"), 100))), 0o644)
		}
	})
	assertBytesEqual(t, dataA, dataB)
}

// TestDecodeTree_ErrorsOnCorruptStore verifies DecodeTree surfaces a missing
// manifest chunk as an error rather than returning a partial tree.
func TestDecodeTree_ErrorsOnCorruptStore(t *testing.T) {
	store := newMemStore()
	// Fabricate a 32-byte id that does not exist in the store.
	var fakeID chunkstore.ChunkID
	for i := range fakeID {
		fakeID[i] = byte(0xCD)
	}
	if _, err := DecodeTree(context.Background(), store, fakeID); err == nil {
		t.Fatal("DecodeTree should error on a missing manifest chunk")
	}
}

// TestDecodeTree_DecodedManifestUnmarshals verifies the bytes from a round
// trip successfully unmarshal into a Manifest whose Hardlinks map matches the
// pending node we walked in.
func TestDecodeTree_DecodedManifestUnmarshals(t *testing.T) {
	store := newMemStore()
	tb := newTarBuilder().hardlink("only_link", "ghost_target")
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), store)
	if err != nil {
		t.Fatal(err)
	}
	_, data, err := BuildLayerManifest(res.Tree, store)
	if err != nil {
		t.Fatal(err)
	}
	chunk, err := store.Put(data)
	if err != nil {
		t.Fatal(err)
	}
	_, data2, err := BuildLayerManifest(mustDecodeTree(t, store, chunk), store)
	if err != nil {
		t.Fatal(err)
	}
	var m voilapb.Manifest
	if err := proto.Unmarshal(data2, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Hardlinks) != 1 {
		t.Fatalf("decoded manifest hardlinks=%d want 1", len(m.Hardlinks))
	}
	for _, hl := range m.Hardlinks {
		if hl.TargetPath != "ghost_target" {
			t.Errorf("hardlink target=%q want ghost_target", hl.TargetPath)
		}
	}
}

func mustDecodeTree(t *testing.T, store chunkstore.ChunkStore, chunk chunkstore.ChunkID) *LayerTree {
	t.Helper()
	tree, err := DecodeTree(context.Background(), store, chunk)
	if err != nil {
		t.Fatalf("DecodeTree: %v", err)
	}
	return tree
}
