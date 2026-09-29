package chunkstore

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func newTestStore(t *testing.T) *LocalStore {
	t.Helper()
	dir := t.TempDir()
	s, err := OpenLocal(dir)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestRoundtripSmallRaw(t *testing.T) {
	s := newTestStore(t)
	buf := []byte("hello world")
	id, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := s.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !bytes.Equal(got, buf) {
		t.Fatalf("Get returned %q, want %q", got, buf)
	}
	m, ok := s.Stat(id)
	if !ok {
		t.Fatal("Stat: not found")
	}
	if m.LogicalLen != uint64(len(buf)) {
		t.Fatalf("LogicalLen = %d, want %d", m.LogicalLen, len(buf))
	}
	if m.StoredLen != m.LogicalLen {
		t.Fatalf("StoredLen = %d, want %d (raw)", m.StoredLen, m.LogicalLen)
	}
}

func TestRoundtripCompressible(t *testing.T) {
	s := newTestStore(t)
	buf := bytes.Repeat([]byte("the quick brown fox jumps over the lazy dog. "), (1<<20)/45+1)
	id, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := s.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !bytes.Equal(got, buf) {
		t.Fatalf("Get mismatch (len got=%d want=%d)", len(got), len(buf))
	}
	m, ok := s.Stat(id)
	if !ok {
		t.Fatal("Stat not found")
	}
	if m.StoredLen >= m.LogicalLen {
		t.Fatalf("expected compression: StoredLen=%d LogicalLen=%d", m.StoredLen, m.LogicalLen)
	}
}

func TestRoundtripIncompressible(t *testing.T) {
	s := newTestStore(t)
	buf := make([]byte, 1<<17)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}
	id, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, err := s.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !bytes.Equal(got, buf) {
		t.Fatal("Get mismatch")
	}
	m, _ := s.Stat(id)
	if m.StoredLen != m.LogicalLen {
		t.Fatalf("expected raw: StoredLen=%d LogicalLen=%d", m.StoredLen, m.LogicalLen)
	}
}

func TestPutIdempotent(t *testing.T) {
	s := newTestStore(t)
	buf := bytes.Repeat([]byte("idempotent payload "), 1000)
	id1, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put 1: %v", err)
	}
	id2, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put 2: %v", err)
	}
	if id1 != id2 {
		t.Fatalf("ids differ: %v vs %v", id1, id2)
	}
	// Exactly one blob path on disk.
	path := blobPath(s.root, id1)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat blob: %v", err)
	}
	if info.Size() == 0 {
		t.Fatal("blob file is empty")
	}
	// Count blobs in the chunks dir; should be 1.
	n := countBlobs(t, filepath.Join(s.root, "chunks"))
	if n != 1 {
		t.Fatalf("found %d blob(s), want 1", n)
	}
}

func TestStatAbsent(t *testing.T) {
	s := newTestStore(t)
	var id ChunkID
	id[0] = 0xff
	if _, ok := s.Stat(id); ok {
		t.Fatal("Stat returned true for absent chunk")
	}
	// And the absent Stat must not have created a blob or row.
	n := countBlobs(t, filepath.Join(s.root, "chunks"))
	if n != 0 {
		t.Fatalf("found %d blob(s) after Stat, want 0", n)
	}
}

func TestGetMissing(t *testing.T) {
	s := newTestStore(t)
	var id ChunkID
	id[0] = 1
	_, err := s.Get(context.Background(), id)
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get on missing id: err = %v, want ErrNotFound", err)
	}
}

func TestCorruptBlob(t *testing.T) {
	s := newTestStore(t)
	buf := bytes.Repeat([]byte("corrupt me "), 5000)
	id, err := s.Put(buf)
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	// Corrupt the on-disk blob.
	path := blobPath(s.root, id)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatalf("open blob: %v", err)
	}
	if _, err := f.Write([]byte("garbage")); err != nil {
		_ = f.Close()
		t.Fatalf("write garbage: %v", err)
	}
	_ = f.Close()

	_, err = s.Get(context.Background(), id)
	if err == nil {
		t.Fatal("expected error from corrupt blob, got nil")
	}
	if !errors.Is(err, ErrNotFound) && err.Error() == "" {
		t.Fatalf("unexpected empty error")
	}
	// Error should mention the chunk id (in hex).
	if !contains(err.Error(), id.String()) {
		t.Fatalf("error %q should mention chunk id %q", err.Error(), id.String())
	}
}

func TestGC(t *testing.T) {
	s := newTestStore(t)
	a, _ := s.Put([]byte("AAAA"))
	b, _ := s.Put(bytes.Repeat([]byte("B"), 100))
	c, _ := s.Put([]byte("CCCC"))

	reachable := map[ChunkID]struct{}{a: {}, c: {}}
	removed, err := s.GC(reachable)
	if err != nil {
		t.Fatalf("GC: %v", err)
	}
	if removed != 1 {
		t.Fatalf("removed = %d, want 1", removed)
	}
	// B should be gone.
	if _, err := os.Stat(blobPath(s.root, b)); !os.IsNotExist(err) {
		t.Fatalf("B blob should be gone, stat err = %v", err)
	}
	if _, err := s.Get(context.Background(), b); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(B) err = %v, want ErrNotFound", err)
	}
	// A and C still retrievable.
	if _, err := s.Get(context.Background(), a); err != nil {
		t.Fatalf("Get(A): %v", err)
	}
	if _, err := s.Get(context.Background(), c); err != nil {
		t.Fatalf("Get(C): %v", err)
	}
	// Second GC with all reachable removes 0.
	removed2, err := s.GC(map[ChunkID]struct{}{a: {}, c: {}})
	if err != nil {
		t.Fatalf("GC 2: %v", err)
	}
	if removed2 != 0 {
		t.Fatalf("removed2 = %d, want 0", removed2)
	}
}

func TestReopen(t *testing.T) {
	dir := t.TempDir()
	s1, err := OpenLocal(dir)
	if err != nil {
		t.Fatalf("OpenLocal 1: %v", err)
	}
	buf := bytes.Repeat([]byte("persisted payload "), 5000)
	id, err := s1.Put(buf)
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenLocal(dir)
	if err != nil {
		t.Fatalf("OpenLocal 2: %v", err)
	}
	defer s2.Close()
	got, err := s2.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get after reopen: %v", err)
	}
	if !bytes.Equal(got, buf) {
		t.Fatal("data mismatch after reopen")
	}
	if _, ok := s2.Stat(id); !ok {
		t.Fatal("Stat false after reopen")
	}
}

// --- helpers ---

// TestConcurrentPutGet hammers the store (and the shared zstd encoder/decoder)
// from many goroutines to flush out lazy-init races under `go test -race`.
func TestConcurrentPutGet(t *testing.T) {
	s := newTestStore(t)
	payloads := [][]byte{
		[]byte("tiny"),
		bytes.Repeat([]byte("compressible payload payload payload "), 5000),
		make([]byte, 1<<16), // incompressible-ish, filled below
	}
	if _, err := rand.Read(payloads[2]); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}

	const goroutines = 16
	const iters = 50
	var wg sync.WaitGroup
	wg.Add(goroutines)
	for g := 0; g < goroutines; g++ {
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				buf := payloads[i%len(payloads)]
				id, err := s.Put(buf)
				if err != nil {
					t.Errorf("Put: %v", err)
					return
				}
				got, err := s.Get(context.Background(), id)
				if err != nil {
					t.Errorf("Get: %v", err)
					return
				}
				if !bytes.Equal(got, buf) {
					t.Errorf("Get mismatch for id %s", id)
					return
				}
				if _, ok := s.Stat(id); !ok {
					t.Errorf("Stat miss for id %s", id)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func countBlobs(t *testing.T, root string) int {
	t.Helper()
	n := 0
	err := filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if !info.IsDir() {
			n++
		}
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("walk: %v", err)
	}
	return n
}

func contains(haystack, needle string) bool {
	return bytes.Contains([]byte(haystack), []byte(needle))
}

// TestPruneAll_WipesEverything puts a few chunks, drops an orphaned blob into
// the chunks dir (simulating a crash-lost index row), then PruneAll: every
// index row, blob file, and the orphan must be gone; Count reports zero; and
// the store must remain usable (Put/Get roundtrip after prune).
func TestPruneAll_WipesEverything(t *testing.T) {
	s := newTestStore(t)
	ids := make([]ChunkID, 3)
	for i := range ids {
		id, err := s.Put([]byte(fmt.Sprintf("prune me %d", i)))
		if err != nil {
			t.Fatalf("Put %d: %v", i, err)
		}
		ids[i] = id
	}

	// Orphaned blob: on disk but not in the index.
	orphanDir := filepath.Join(s.root, "chunks", "or")
	if err := os.MkdirAll(orphanDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(orphanDir, "deadbeef"), []byte("orphan"), 0o644); err != nil {
		t.Fatal(err)
	}

	n, bytesBefore, err := s.Count()
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if n != 3 {
		t.Fatalf("Count before prune = %d, want 3", n)
	}
	if bytesBefore == 0 {
		t.Fatal("Count bytes = 0, want > 0")
	}

	removed, freedBytes, err := s.PruneAll()
	if err != nil {
		t.Fatalf("PruneAll: %v", err)
	}
	if removed != 3 {
		t.Fatalf("PruneAll removed = %d, want 3", removed)
	}
	if freedBytes != bytesBefore {
		t.Fatalf("PruneAll bytes = %d, want %d", freedBytes, bytesBefore)
	}
	if got := countBlobs(t, filepath.Join(s.root, "chunks")); got != 0 {
		t.Fatalf("blob files after prune = %d, want 0 (orphan not swept?)", got)
	}
	if n, _, err := s.Count(); err != nil || n != 0 {
		t.Fatalf("Count after prune = %d, %v; want 0, nil", n, err)
	}

	// Store remains usable.
	id, err := s.Put([]byte("fresh after prune"))
	if err != nil {
		t.Fatalf("Put after prune: %v", err)
	}
	got, err := s.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get after prune: %v", err)
	}
	if string(got) != "fresh after prune" {
		t.Fatalf("Get after prune returned %q", got)
	}
	for _, old := range ids {
		if _, err := s.Get(context.Background(), old); !errors.Is(err, ErrNotFound) {
			t.Fatalf("Get pruned chunk: err = %v, want ErrNotFound", err)
		}
	}
}
