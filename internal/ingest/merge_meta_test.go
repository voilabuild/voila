package ingest

import (
	"archive/tar"
	"bytes"
	"context"
	"testing"
)

// walkTar is a small helper: build a layer tree from a tarBuilder.
func walkTar(t *testing.T, tb *tarBuilder) *LayerTree {
	t.Helper()
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), newMemStore())
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}
	return res.Tree
}

// A lower layer's real dir metadata must survive an upper layer that only
// references paths beneath the dir (implicit ensureDir ancestors must not
// clobber 0700 uid/gid 999 with placeholder 0755 root:root).
func TestMerge_ImplicitUpperDirPreservesLowerMeta(t *testing.T) {
	lowerTB := newTarBuilder()
	lowerTB.write(&tar.Header{
		Name: "data/", Mode: 0o700, Uid: 999, Gid: 999, Typeflag: tar.TypeDir,
	}, nil)
	lower := walkTar(t, lowerTB)

	upperTB := newTarBuilder()
	upperTB.file("data/sub/file.txt", []byte("x"), 0o644) // no explicit "data/" entry
	upper := walkTar(t, upperTB)

	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatalf("MergeTrees: %v", err)
	}
	d := merged.Lookup("data")
	if d == nil || d.Type != NodeDir {
		t.Fatalf("merged data dir missing")
	}
	if d.Mode != 0o700 || d.Uid != 999 || d.Gid != 999 {
		t.Fatalf("lower dir metadata clobbered: mode=%o uid=%d gid=%d, want 700/999/999",
			d.Mode, d.Uid, d.Gid)
	}
	if merged.Lookup("data/sub/file.txt") == nil {
		t.Fatalf("upper file missing from merge")
	}
}

// The inverse: an explicit upper dir entry still overrides lower metadata.
func TestMerge_ExplicitUpperDirOverridesLowerMeta(t *testing.T) {
	lowerTB := newTarBuilder()
	lowerTB.write(&tar.Header{
		Name: "data/", Mode: 0o700, Uid: 999, Gid: 999, Typeflag: tar.TypeDir,
	}, nil)
	lower := walkTar(t, lowerTB)

	upperTB := newTarBuilder()
	upperTB.write(&tar.Header{
		Name: "data/", Mode: 0o755, Uid: 0, Gid: 0, Typeflag: tar.TypeDir,
	}, nil)
	upper := walkTar(t, upperTB)

	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatalf("MergeTrees: %v", err)
	}
	d := merged.Lookup("data")
	if d == nil || d.Mode != 0o755 || d.Uid != 0 || d.Gid != 0 {
		t.Fatalf("explicit upper dir should win: got mode=%o uid=%d gid=%d", d.Mode, d.Uid, d.Gid)
	}
}

// An implicit layer ROOT must not clobber a lower layer's explicit root
// metadata either.
func TestMerge_ImplicitUpperRootPreservesLowerRootMeta(t *testing.T) {
	lowerTB := newTarBuilder()
	lowerTB.write(&tar.Header{
		Name: "./", Mode: 0o750, Uid: 7, Gid: 7, Typeflag: tar.TypeDir,
	}, nil)
	lower := walkTar(t, lowerTB)

	upperTB := newTarBuilder()
	upperTB.file("f", []byte("y"), 0o644) // no explicit root entry
	upper := walkTar(t, upperTB)

	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatalf("MergeTrees: %v", err)
	}
	r := merged.Root
	if r.Mode != 0o750 || r.Uid != 7 || r.Gid != 7 {
		t.Fatalf("root metadata clobbered: mode=%o uid=%d gid=%d, want 750/7/7", r.Mode, r.Uid, r.Gid)
	}
}
