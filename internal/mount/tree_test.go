package mount

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"lukechampine.com/blake3"

	"google.golang.org/protobuf/proto"
)

// memStore is an in-memory ChunkStore (BLAKE3 content id, matching LocalStore)
// that also counts Get invocations for the lazy-load tests.
type memStore struct {
	mu     sync.Mutex
	chunks map[chunkstore.ChunkID][]byte
	gets   int
}

func newMemStore() *memStore { return &memStore{chunks: make(map[chunkstore.ChunkID][]byte)} }

func (s *memStore) Put(buf []byte) (chunkstore.ChunkID, error) {
	id := chunkstore.ChunkID(blake3.Sum256(buf))
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.chunks[id]; !ok {
		cp := make([]byte, len(buf))
		copy(cp, buf)
		s.chunks[id] = cp
	}
	return id, nil
}

func (s *memStore) Get(_ context.Context, id chunkstore.ChunkID) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gets++
	b, ok := s.chunks[id]
	if !ok {
		return nil, chunkstore.ErrNotFound
	}
	return b, nil
}

func (s *memStore) Stat(id chunkstore.ChunkID) (chunkstore.ChunkMeta, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.chunks[id]
	if !ok {
		return chunkstore.ChunkMeta{}, false
	}
	return chunkstore.ChunkMeta{LogicalLen: uint64(len(b)), StoredLen: uint64(len(b))}, true
}

func (s *memStore) GC(_ map[chunkstore.ChunkID]struct{}) (int, error) { return 0, nil }
func (s *memStore) Close() error                                      { return nil }

func (s *memStore) GetCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gets
}

// putManifest marshals m deterministically and stores it, returning the chunk
// id (the same id the Tree will compute via store.Get when given back).
func putManifest(t *testing.T, store *memStore, m *voilapb.Manifest) chunkstore.ChunkID {
	t.Helper()
	data, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, m)
	if err != nil {
		t.Fatalf("marshal manifest: %v", err)
	}
	id, err := store.Put(data)
	if err != nil {
		t.Fatalf("put manifest: %v", err)
	}
	return id
}

// chunkIDFromBytes wraps a 32-byte slice into a ChunkID.
func chunkIDFromBytes(b []byte) chunkstore.ChunkID {
	var id chunkstore.ChunkID
	copy(id[:], b)
	return id
}

// buildTwoTierManifest constructs a parent manifest with a top-level dir (inode
// 1), one inlined file ("top.txt", inode 4), one inlined symlink ("link",
// inode 5) and one externallized dir ("sub", inode 2) whose child manifest
// contains a single file ("sub/inside.txt", inode 3). It returns the parent
// chunk id plus the child dir inode and key inodes so tests have handles.
func buildTwoTierManifest(t *testing.T, store *memStore) (rootID chunkstore.ChunkID, inodes struct {
	Root, Sub, InsideFile, TopFile, Symlink uint64
}) {
	t.Helper()
	// "inside.txt" content chunk.
	content := []byte("hello from external subtree\n")
	cid, err := store.Put(content)
	if err != nil {
		t.Fatalf("put inside content: %v", err)
	}

	child := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{Inode: 2, Mode: 0o755, Entries: map[string]uint64{"inside.txt": 3}},
		},
		Files: map[uint64]*voilapb.File{
			3: {
				Inode: 3, Mode: 0o644, Size: uint64(len(content)),
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: append([]byte(nil), cid[:]...), LogicalLen: uint64(len(content))},
				},
			},
		},
	}
	childCID := putManifest(t, store, child)

	parent := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{
				Inode:   1,
				Mode:    0o755,
				Entries: map[string]uint64{"sub": 2, "top.txt": 4, "link": 5},
			},
		},
		Files: map[uint64]*voilapb.File{
			4: {Inode: 4, Mode: 0o644, Size: 0}, // empty top-level file
		},
		Symlinks: map[uint64]*voilapb.Symlink{
			5: {Inode: 5, Target: "top.txt"},
		},
		ExternalSubtrees: map[uint64][]byte{
			2: append([]byte(nil), childCID[:]...),
		},
	}
	parentCID := putManifest(t, store, parent)

	return parentCID, struct {
		Root, Sub, InsideFile, TopFile, Symlink uint64
	}{1, 2, 3, 4, 5}
}

func TestTree_LoadFetchesOnlyRootChunk(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	_ = inodes

	ctx := context.Background()
	tr, err := Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := store.GetCount(); got != 1 {
		t.Fatalf("Load should fetch exactly the root chunk, got %d Get calls", got)
	}
	if tr.Root() != 1 {
		t.Fatalf("Root() = %d, want 1", tr.Root())
	}
}

func TestTree_GetRootWithoutLoadingSubtrees(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Top-level inlined file is resolvable without loading the subtree.
	info, err := tr.Get(context.Background(), inodes.TopFile)
	if err != nil {
		t.Fatalf("Get top file: %v", err)
	}
	if info.Kind != KindFile || info.File == nil {
		t.Fatalf("Get top file kind=%v File=%v", info.Kind, info.File)
	}
	if got := store.GetCount(); got != 1 {
		t.Fatalf("resolving an inlined node should not fetch any child chunks, got %d", got)
	}
}

func TestTree_LookupCrossesExternalSubtreeTriggersOneExtraGet(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := store.GetCount(); got != 1 {
		t.Fatalf("after Load: Get calls = %d, want 1", got)
	}

	// Lookup("sub") inside root dir crosses the external subtree boundary.
	info, err := tr.Lookup(context.Background(), inodes.Root, "sub")
	if err != nil {
		t.Fatalf("Lookup sub: %v", err)
	}
	if info.Kind != KindDir || info.Dir == nil {
		t.Fatalf("Lookup sub: kind=%v Dir=%v", info.Kind, info.Dir)
	}
	if got := store.GetCount(); got != 2 {
		t.Fatalf("after Lookup(sub): Get calls = %d, want 2 (root + child)", got)
	}

	// Subsequent lookups inside the now-loaded subtree should add no fetches.
	if _, err := tr.Lookup(context.Background(), inodes.Root, "sub"); err != nil {
		t.Fatalf("Lookup sub twice: %v", err)
	}
	if got := store.GetCount(); got != 2 {
		t.Fatalf("after repeated Lookup(sub): Get calls = %d, want 2", got)
	}

	// Lookup deep: "inside.txt" inside the loaded subtree is cached already.
	inside, err := tr.Lookup(context.Background(), inodes.Sub, "inside.txt")
	if err != nil {
		t.Fatalf("Lookup inside.txt: %v", err)
	}
	if inside.Kind != KindFile || inside.File == nil {
		t.Fatalf("Lookup inside.txt: kind=%v File=%v", inside.Kind, inside.File)
	}
	if got := store.GetCount(); got != 2 {
		t.Fatalf("after Lookup(inside.txt): Get calls = %d, want 2", got)
	}
}

func TestTree_ReadDirSorted(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	entries, err := tr.ReadDir(context.Background(), inodes.Root)
	if err != nil {
		t.Fatalf("ReadDir root: %v", err)
	}
	gotNames := make([]string, len(entries))
	for i, e := range entries {
		gotNames[i] = e.Name
	}
	wantNames := []string{"link", "sub", "top.txt"}
	if fmt.Sprintf("%v", gotNames) != fmt.Sprintf("%v", wantNames) {
		t.Fatalf("ReadDir order = %v, want %v", gotNames, wantNames)
	}
	// Kinds should be resolved correctly.
	kindOf := map[string]NodeKind{}
	for _, e := range entries {
		kindOf[e.Name] = e.Kind
	}
	if kindOf["link"] != KindSymlink {
		t.Errorf("link kind = %v, want KindSymlink", kindOf["link"])
	}
	if kindOf["sub"] != KindDir {
		t.Errorf("sub kind = %v, want KindDir", kindOf["sub"])
	}
	if kindOf["top.txt"] != KindFile {
		t.Errorf("top.txt kind = %v, want KindFile", kindOf["top.txt"])
	}
}

func TestTree_ErrNotFound(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Unknown name.
	if _, err := tr.Lookup(context.Background(), inodes.Root, "does-not-exist"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Lookup unknown: err=%v, want ErrNotFound", err)
	}
	// Unknown inode (one that no loaded manifest and no external_subtree maps
	// to).
	if _, err := tr.Get(context.Background(), 999_999); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get unknown inode: err=%v, want ErrNotFound", err)
	}
	// Get on a non-dir inode must report "not a directory" - NOT ErrNotFound,
	// since Lookup of unknown names should surface ErrNotFound instead.
	if _, err := tr.Lookup(context.Background(), inodes.TopFile, "anything"); err == nil {
		t.Fatalf("Lookup on a non-dir inode should fail")
	}
}

func TestTree_ReadDirOfExternalSubtreeLoadsOnce(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// ReadDir on root resolves "sub" (one external load), then "top.txt" and
	// "link" (both cached). After: exactly 2 Get calls.
	if _, err := tr.ReadDir(context.Background(), inodes.Root); err != nil {
		t.Fatalf("ReadDir root: %v", err)
	}
	if got := store.GetCount(); got != 2 {
		t.Fatalf("ReadDir(root) should end at 2 Gets (root + one child), got %d", got)
	}
}

// Ensure a file resolved via ReadAt through the tree matches the stored bytes.
// This exercises Tree.Get → filereader.ReadAt integration with the chunk store.
func TestTree_ReadThroughFile(t *testing.T) {
	store := newMemStore()
	rootID, inodes := buildTwoTierManifest(t, store)
	tr, err := Load(context.Background(), store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	inside, err := tr.Lookup(context.Background(), inodes.Sub, "inside.txt")
	if err != nil {
		t.Fatalf("Lookup inside.txt: %v", err)
	}
	dst := make([]byte, 1024)
	n, err := ReadAt(context.Background(), store, inside.File, dst, 0)
	if err != nil && err != io.EOF {
		t.Fatalf("ReadAt: %v", err)
	}
	want := []byte("hello from external subtree\n")
	if !bytes.Equal(dst[:n], want) {
		t.Fatalf("ReadAt body = %q, want %q", dst[:n], want)
	}
}

// TestTree_PrefetchManifests verifies the parallel manifest prefetcher loads
// every external subtree (multi-level) and that Gets are issued concurrently
// (bounded by the concurrency argument), not one at a time.
func TestTree_PrefetchManifests(t *testing.T) {
	store := newMemStore()
	// Three-tier tree: root -> sub (inode 2) -> deep (inode 6).
	deep := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 6, Mode: 0o755, Entries: map[string]uint64{"leaf.txt": 7}}},
		Files: map[uint64]*voilapb.File{
			7: {Inode: 7, Mode: 0o644, Size: 1},
		},
	}
	deepCID := putManifest(t, store, deep)
	sub := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 2, Mode: 0o755, Entries: map[string]uint64{"deep": 6}}},
		ExternalSubtrees: map[uint64][]byte{
			6: append([]byte(nil), deepCID[:]...),
		},
	}
	subCID := putManifest(t, store, sub)
	root := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 1, Mode: 0o755, Entries: map[string]uint64{"sub": 2}}},
		ExternalSubtrees: map[uint64][]byte{
			2: append([]byte(nil), subCID[:]...),
		},
	}
	rootCID := putManifest(t, store, root)

	tr, err := Load(context.Background(), store, rootCID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := store.GetCount(); got != 1 {
		t.Fatalf("after Load: Get calls = %d, want 1 (root only)", got)
	}

	tr.PrefetchManifests(context.Background(), 2)

	// Both subtrees loaded: deep leaf must resolve without extra fetches.
	if got := store.GetCount(); got != 3 {
		t.Fatalf("after PrefetchManifests: Get calls = %d, want 3 (root+sub+deep)", got)
	}
	leaf, err := tr.Lookup(context.Background(), 6, "leaf.txt")
	if err != nil {
		t.Fatalf("Lookup deep leaf: %v", err)
	}
	if leaf.Kind != KindFile {
		t.Fatalf("deep leaf kind = %v, want KindFile", leaf.Kind)
	}
	if got := store.GetCount(); got != 3 {
		t.Fatalf("after Lookup deep leaf: Get calls = %d, want 3 (no new fetch)", got)
	}
}

// concurrentStore records the peak number of simultaneous Get calls so tests
// can assert prefetch actually runs in parallel.
type concurrentStore struct {
	*memStore
	mu   sync.Mutex
	cur  int
	peak int
}

func (s *concurrentStore) Get(ctx context.Context, id chunkstore.ChunkID) ([]byte, error) {
	s.mu.Lock()
	s.cur++
	if s.cur > s.peak {
		s.peak = s.cur
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.cur--
		s.mu.Unlock()
	}()
	time.Sleep(5 * time.Millisecond)
	return s.memStore.Get(ctx, id)
}

// TestTree_PrefetchManifestsParallel asserts the prefetch issues Gets
// concurrently (peak concurrency > 1), not serially.
func TestTree_PrefetchManifestsParallel(t *testing.T) {
	store := &concurrentStore{memStore: newMemStore()}
	// Root with 4 sibling external subtrees (inodes 2..5).
	subs := make([]chunkstore.ChunkID, 4)
	for i := 0; i < 4; i++ {
		ino := uint64(2 + i)
		m := &voilapb.Manifest{
			Dirs: []*voilapb.Dir{{Inode: ino, Mode: 0o755, Entries: map[string]uint64{}}},
		}
		subs[i] = putManifest(t, store.memStore, m)
	}
	root := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{{Inode: 1, Mode: 0o755, Entries: map[string]uint64{"a": 2, "b": 3, "c": 4, "d": 5}}},
		ExternalSubtrees: map[uint64][]byte{
			2: append([]byte(nil), subs[0][:]...),
			3: append([]byte(nil), subs[1][:]...),
			4: append([]byte(nil), subs[2][:]...),
			5: append([]byte(nil), subs[3][:]...),
		},
	}
	rootCID := putManifest(t, store.memStore, root)
	tr, err := Load(context.Background(), store, rootCID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	tr.PrefetchManifests(context.Background(), 4)
	store.mu.Lock()
	peak := store.peak
	store.mu.Unlock()
	if peak < 2 {
		t.Fatalf("prefetch peak concurrency = %d, want >= 2 (parallel fetch)", peak)
	}
	if got := store.GetCount(); got != 5 {
		t.Fatalf("after prefetch: Get calls = %d, want 5 (root + 4 subtrees)", got)
	}
}
