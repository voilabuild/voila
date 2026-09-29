package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
)

// pruneState snapshots everything `voila images prune` is supposed to wipe:
// image rows, layer cache rows, .pb manifest files, and chunk blob files.
func pruneState(t *testing.T, root string) (rows int, layers int, pbFiles int, blobFiles int) {
	t.Helper()
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("open image store: %v", err)
	}
	defer imgStore.Close()
	recs, err := imgStore.List()
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	rows = len(recs)
	if layers, err = imgStore.CountLayerCacheRows(); err != nil {
		t.Fatalf("count layers: %v", err)
	}
	pbFiles = countFilesWithExt(t, filepath.Join(root, "images"), ".pb")
	blobFiles = countChunksFiles(t, root)
	return rows, layers, pbFiles, blobFiles
}

// countFilesWithExt counts regular files with ext under dir (non-recursive
// for .pb; the manifests live flat in <root>/images/).
func countFilesWithExt(t *testing.T, dir, ext string) int {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0
		}
		t.Fatalf("read dir %s: %v", dir, err)
	}
	n := 0
	for _, e := range entries {
		if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ext) {
			n++
		}
	}
	return n
}

// TestImagesPrune_Force_WipesEverything ingests a fixture, runs
// `voila images prune -f`, and asserts every trace of local state is gone:
// images rows, layer cache rows, .pb manifests, and chunk blobs. The output
// must report what was removed.
func TestImagesPrune_Force_WipesEverything(t *testing.T) {
	const ref = "pruneme:v1"
	root, chunks := ingestTinyFixture(t, ref)
	if chunks == 0 {
		t.Fatal("fixture produced no chunks")
	}

	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &out}
	if err := cmdImages(cfg, []string{"prune", "-f"}); err != nil {
		t.Fatalf("cmdImages prune -f: %v", err)
	}

	rows, cacheRows, pbs, blobs := pruneState(t, root)
	if rows != 0 || cacheRows != 0 || pbs != 0 || blobs != 0 {
		t.Fatalf("state after prune: rows=%d layers=%d pb=%d blobs=%d, want all 0",
			rows, cacheRows, pbs, blobs)
	}
	if !strings.Contains(out.String(), "removed 1 image(s)") ||
		!strings.Contains(out.String(), "chunk(s)") {
		t.Errorf("prune output missing removal summary: %q", out.String())
	}
}

// TestImagesPrune_PromptDecline feeds "n" to the confirmation prompt and
// asserts NOTHING was deleted.
func TestImagesPrune_PromptDecline(t *testing.T) {
	const ref = "keepme:v1"
	root, _ := ingestTinyFixture(t, ref)
	beforeRows, beforeLayers, beforePbs, beforeBlobs := pruneState(t, root)

	var out bytes.Buffer
	cfg := Config{
		Root:   root,
		Stdout: &out,
		Stderr: &out,
		Stdin:  strings.NewReader("n\n"),
	}
	if err := cmdImages(cfg, []string{"prune"}); err != nil {
		t.Fatalf("cmdImages prune (declined): %v", err)
	}

	rows, layers, pbs, blobs := pruneState(t, root)
	if rows != beforeRows || layers != beforeLayers || pbs != beforePbs || blobs != beforeBlobs {
		t.Fatalf("declined prune mutated state: rows=%d layers=%d pb=%d blobs=%d (before %d/%d/%d/%d)",
			rows, layers, pbs, blobs, beforeRows, beforeLayers, beforePbs, beforeBlobs)
	}
	if !strings.Contains(out.String(), "aborted") {
		t.Errorf("expected abort message, got: %q", out.String())
	}
}

// TestImagesPrune_PromptAccept feeds "y" to the prompt and asserts the same
// wipe as -f.
func TestImagesPrune_PromptAccept(t *testing.T) {
	const ref = "acceptme:v1"
	root, _ := ingestTinyFixture(t, ref)

	var out bytes.Buffer
	cfg := Config{
		Root:   root,
		Stdout: &out,
		Stderr: &out,
		Stdin:  strings.NewReader("y\n"),
	}
	if err := cmdImages(cfg, []string{"prune"}); err != nil {
		t.Fatalf("cmdImages prune (accepted): %v", err)
	}

	rows, cacheRows, pbs, blobs := pruneState(t, root)
	if rows != 0 || cacheRows != 0 || pbs != 0 || blobs != 0 {
		t.Fatalf("accepted prune left state: rows=%d layers=%d pb=%d blobs=%d",
			rows, cacheRows, pbs, blobs)
	}
}

// TestImagesPrune_StoreUsableAfter prunes, then re-ingests into the same
// root: the stores must come back clean and fully functional.
func TestImagesPrune_StoreUsableAfter(t *testing.T) {
	const ref = "reusable:v1"
	root, _ := ingestTinyFixture(t, ref)

	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &out}
	if err := cmdImages(cfg, []string{"prune", "-f"}); err != nil {
		t.Fatalf("prune: %v", err)
	}

	// Re-ingest a DIFFERENT image into the same root.
	content := []byte("post-prune ingest")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	cfg2 := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg2, root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("re-ingest after prune: %v", err)
	}

	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer imgStore.Close()
	im, _, err := imagestore.Resolve(imgStore, ref)
	if err != nil {
		t.Fatalf("resolve re-ingested ref: %v", err)
	}
	if im.GetImageRef() != ref {
		t.Errorf("re-ingested manifest ref = %q, want %q", im.GetImageRef(), ref)
	}
	// Its chunks must be readable from the (recreated) chunk store. The
	// merged-root manifest chunk is the root of the image's chunk closure.
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	_, rootChunk, err := imagestore.Resolve(imgStore, ref)
	if err != nil {
		t.Fatalf("resolve for root chunk: %v", err)
	}
	if _, err := store.Get(context.Background(), rootChunk); err != nil {
		t.Fatalf("Get re-ingested root manifest chunk: %v", err)
	}
}
