package main

import (
	"bytes"
	"strings"
	"testing"

	"voila/internal/imagestore"
)

// TestCmdTag_RetagsLocalImage ingests a fixture, retags it to a new ref via
// `voila tag`, and asserts both the new ref resolves to a manifest AND the
// original ref still resolves (tagging adds a handle, never removes one). The
// new ref must carry the same digest + merged-root chunk as the source.
func TestCmdTag_RetagsLocalImage(t *testing.T) {
	const src = "tagme:v1"
	const newRef = "myorg/python:3.13"
	root, _ := ingestTinyFixture(t, src)

	// Capture the source manifest before tagging.
	srcStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("open image store: %v", err)
	}
	srcIm, _, err := imagestore.Resolve(srcStore, src)
	if err != nil {
		t.Fatalf("resolve src: %v", err)
	}
	srcDigest := srcIm.GetImageDigest()
	srcRoot := srcIm.GetMergedRootManifestChunk()
	_ = srcStore.Close()

	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}}
	if err := cmdTag(cfg, []string{src, newRef}); err != nil {
		t.Fatalf("cmdTag: %v", err)
	}
	if !strings.Contains(out.String(), "-> "+newRef) {
		t.Errorf("tag output missing new ref: %q", out.String())
	}

	// New ref resolves and matches the source digest + merged-root chunk.
	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("open image store: %v", err)
	}
	defer store.Close()
	newIm, _, err := imagestore.Resolve(store, newRef)
	if err != nil {
		t.Fatalf("resolve new ref: %v", err)
	}
	if newIm.GetImageRef() != newRef {
		t.Errorf("new manifest image_ref = %q, want %q", newIm.GetImageRef(), newRef)
	}
	if !bytes.Equal(newIm.GetImageDigest(), srcDigest) {
		t.Errorf("digest mismatch: got %x want %x", newIm.GetImageDigest(), srcDigest)
	}
	if !bytes.Equal(newIm.GetMergedRootManifestChunk(), srcRoot) {
		t.Errorf("merged-root chunk mismatch after tag")
	}

	// Original ref still resolves (tagging is additive).
	if _, _, err := imagestore.Resolve(store, src); err != nil {
		t.Errorf("source ref no longer resolves after tag: %v", err)
	}

	// The new ref should appear in `voila images` listing.
	rows, err := store.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := false
	for _, r := range rows {
		if r.Ref == newRef {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("new ref %q not present in image store rows", newRef)
	}
}

// TestCmdTag_RequiresTwoArgs asserts the usage error for wrong arg count.
func TestCmdTag_RequiresTwoArgs(t *testing.T) {
	cfg := Config{Root: t.TempDir(), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := cmdTag(cfg, []string{"only-one"}); err == nil {
		t.Fatal("cmdTag with one arg should error")
	}
}
