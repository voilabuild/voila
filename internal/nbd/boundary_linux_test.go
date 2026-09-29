//go:build linux

package nbd

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
	"voila/internal/imagestore"
	"voila/internal/mount"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
	"lukechampine.com/blake3"
)

// TestE2E_MultiChunkBoundary mounts a 2 MiB file whose 1 MiB slots are not
// adjacent in the virtual device and checks the EROFS mount returns the
// second chunk's data at byte 1048576 (not zeros).
func TestE2E_MultiChunkBoundary(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root")
	}
	if _, err := os.Stat("/dev/nbd0"); err != nil {
		t.Skip("requires /dev/nbd0")
	}

	store := newMemStore()
	chunkA := filledChunk(0xAA)
	chunkB := filledChunk(0xBB)
	chunkC := filledChunk(0xCC)
	idA, _ := store.Put(chunkA)
	idB, _ := store.Put(chunkB)
	idC, _ := store.Put(chunkC)

	m := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{Inode: 1, Mode: 0o755, Entries: map[string]uint64{
				"a.bin": 2,
				"b.bin": 3,
				"c.bin": 4,
			}},
		},
		Files: map[uint64]*voilapb.File{
			2: {Inode: 2, Mode: 0o644, Size: erofsadapter.ChunkSize, Blocks: []*voilapb.Block{
				{OffsetInFile: 0, ChunkId: idA[:], LogicalLen: erofsadapter.ChunkSize},
			}},
			3: {Inode: 3, Mode: 0o644, Size: erofsadapter.ChunkSize, Blocks: []*voilapb.Block{
				{OffsetInFile: 0, ChunkId: idB[:], LogicalLen: erofsadapter.ChunkSize},
			}},
			4: {Inode: 4, Mode: 0o644, Size: 2 * erofsadapter.ChunkSize, Blocks: []*voilapb.Block{
				{OffsetInFile: 0, ChunkId: idA[:], LogicalLen: erofsadapter.ChunkSize},
				{OffsetInFile: erofsadapter.ChunkSize, ChunkId: idC[:], LogicalLen: erofsadapter.ChunkSize},
			}},
		},
	}
	rootID := putManifest(t, store, m)

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	reg := NewRegistry()
	device, err := reg.Acquire(ctx, "boundary-test", result, store)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer reg.Release("boundary-test")

	mountDir := filepath.Join(t.TempDir(), "erofs")
	if err := os.MkdirAll(mountDir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := syscall.Mount(device.Path(), mountDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		t.Fatalf("mount: %v", err)
	}
	defer syscall.Unmount(mountDir, 0)

	data, err := os.ReadFile(filepath.Join(mountDir, "c.bin"))
	if err != nil {
		t.Fatalf("read c.bin: %v", err)
	}
	if len(data) != 2*erofsadapter.ChunkSize {
		t.Fatalf("c.bin size = %d, want %d", len(data), 2*erofsadapter.ChunkSize)
	}
	if data[0] != 0xAA {
		t.Fatalf("c.bin[0] = 0x%02x, want 0xAA", data[0])
	}
	if data[erofsadapter.ChunkSize] != 0xCC {
		t.Fatalf("c.bin[1MiB] = 0x%02x, want 0xCC (zeros here is the SIGILL corruption)", data[erofsadapter.ChunkSize])
	}
	if data[erofsadapter.ChunkSize-1] != 0xAA {
		t.Fatalf("c.bin[1MiB-1] = 0x%02x, want 0xAA", data[erofsadapter.ChunkSize-1])
	}
}

// TestE2E_AdjacentSlotBoundary covers the minChunkBits path: a 2 MiB file
// whose slots are consecutive becomes one EROFS chunk larger than 1 MiB.
// ReadAt must walk slots or os.ReadFile returns zeros after the first MiB.
func TestE2E_AdjacentSlotBoundary(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root")
	}
	if _, err := os.Stat("/dev/nbd0"); err != nil {
		t.Skip("requires /dev/nbd0")
	}

	store := newMemStore()
	idX, _ := store.Put(filledChunk(0x11))
	idY, _ := store.Put(filledChunk(0x22))
	m := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{Inode: 1, Mode: 0o755, Entries: map[string]uint64{"big.bin": 2}},
		},
		Files: map[uint64]*voilapb.File{
			2: {Inode: 2, Mode: 0o644, Size: 2 * erofsadapter.ChunkSize, Blocks: []*voilapb.Block{
				{OffsetInFile: 0, ChunkId: idX[:], LogicalLen: erofsadapter.ChunkSize},
				{OffsetInFile: erofsadapter.ChunkSize, ChunkId: idY[:], LogicalLen: erofsadapter.ChunkSize},
			}},
		},
	}
	rootID := putManifest(t, store, m)
	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	reg := NewRegistry()
	device, err := reg.Acquire(ctx, "boundary-adj", result, store)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer reg.Release("boundary-adj")

	mountDir := filepath.Join(t.TempDir(), "erofs")
	if err := os.MkdirAll(mountDir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := syscall.Mount(device.Path(), mountDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		t.Fatalf("mount: %v", err)
	}
	defer syscall.Unmount(mountDir, 0)

	big, err := os.ReadFile(filepath.Join(mountDir, "big.bin"))
	if err != nil {
		t.Fatalf("read big.bin: %v", err)
	}
	if big[0] != 0x11 || big[erofsadapter.ChunkSize] != 0x22 {
		t.Fatalf("adjacent-slot file corrupted at 1 MiB: [0]=0x%02x [1MiB]=0x%02x", big[0], big[erofsadapter.ChunkSize])
	}
}

// TestE2E_Postgres1MiBBoundary mounts the ingested postgres:16 image (if
// present) and checks that multi-chunk binaries are intact at the 1 MiB
// boundary — the corruption that caused SIGILL.
func TestE2E_Postgres1MiBBoundary(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root")
	}
	if _, err := os.Stat("/dev/nbd0"); err != nil {
		t.Skip("requires /dev/nbd0")
	}
	root := os.Getenv("VOILA_ROOT")
	if root == "" {
		root = "/tmp/pg-root"
	}

	ctx := context.Background()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Skipf("OpenLocal: %v", err)
	}
	defer store.Close()
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Skipf("imagestore.Open: %v", err)
	}
	defer imgStore.Close()

	var rootChunk chunkstore.ChunkID
	found := false
	for _, ref := range []string{
		"docker.io/library/postgres:16",
		"registry-1.docker.io/library/postgres:16",
	} {
		_, rc, err := imgStore.LoadImageManifest(ref)
		if err == nil {
			rootChunk = rc
			found = true
			t.Logf("using ref %s", ref)
			break
		}
	}
	if !found {
		recs, _ := imgStore.List()
		for _, rec := range recs {
			if _, rc, err := imgStore.LoadImageManifest(rec.Ref); err == nil {
				t.Logf("fallback ref %s", rec.Ref)
				rootChunk = rc
				found = true
				break
			}
		}
	}
	if !found {
		t.Skip("no postgres image ingested")
	}

	tree, err := mount.Load(ctx, store, rootChunk)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	t.Logf("metadata=%d slots=%d", len(result.Metadata), len(result.SlotTable))

	reg := NewRegistry()
	device, err := reg.Acquire(ctx, "pg-boundary", result, store)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer reg.Release("pg-boundary")

	mountDir := filepath.Join(t.TempDir(), "erofs")
	if err := os.MkdirAll(mountDir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := syscall.Mount(device.Path(), mountDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		t.Fatalf("mount: %v", err)
	}
	defer syscall.Unmount(mountDir, 0)

	pgBin := filepath.Join(mountDir, "usr/lib/postgresql/16/bin/postgres")
	data, err := os.ReadFile(pgBin)
	if err != nil {
		t.Fatalf("read postgres: %v", err)
	}
	if len(data) <= erofsadapter.ChunkSize {
		t.Fatalf("postgres size %d is not multi-chunk", len(data))
	}

	info, err := tree.Lookup(ctx, tree.Root(), "usr")
	if err != nil {
		t.Fatalf("lookup usr: %v", err)
	}
	for _, name := range []string{"lib", "postgresql", "16", "bin", "postgres"} {
		info, err = tree.Lookup(ctx, info.Inode, name)
		if err != nil {
			t.Fatalf("lookup %s: %v", name, err)
		}
	}
	if info.File == nil {
		t.Fatal("postgres is not a file")
	}

	want, err := readFileFromStore(ctx, store, info)
	if err != nil {
		t.Fatalf("reconstruct: %v", err)
	}
	if len(want) != len(data) {
		t.Fatalf("size: mounted %d vs store %d", len(data), len(want))
	}

	off := erofsadapter.ChunkSize
	t.Logf("postgres size=%d blocks=%d mount[1MiB]=%x store[1MiB]=%x",
		info.File.Size, len(info.File.Blocks), data[off:off+8], want[off:off+8])
	if data[off] == 0 && data[off+1] == 0 && data[off+2] == 0 && data[off+3] == 0 &&
		(want[off] != 0 || want[off+1] != 0 || want[off+2] != 0 || want[off+3] != 0) {
		t.Fatalf("postgres[1MiB] is zeros on the mount but not in the store (the SIGILL bug)")
	}
	for i := 0; i < 64; i++ {
		if data[off+i] != want[off+i] {
			t.Fatalf("postgres mismatch at %d: mount=0x%02x store=0x%02x", off+i, data[off+i], want[off+i])
		}
	}
	// Spot-check the first 64 bytes too.
	for i := 0; i < 64; i++ {
		if data[i] != want[i] {
			t.Fatalf("postgres mismatch at %d: mount=0x%02x store=0x%02x", i, data[i], want[i])
		}
	}
}

func readFileFromStore(ctx context.Context, store chunkstore.ChunkStore, info *mount.NodeInfo) ([]byte, error) {
	out := make([]byte, info.File.Size)
	for _, b := range info.File.Blocks {
		if len(b.ChunkId) == 0 {
			continue
		}
		var cid chunkstore.ChunkID
		copy(cid[:], b.ChunkId)
		chunk, err := store.Get(ctx, cid)
		if err != nil {
			return nil, err
		}
		n := int(b.LogicalLen)
		if n > len(chunk) {
			n = len(chunk)
		}
		copy(out[b.OffsetInFile:int(b.OffsetInFile)+n], chunk[:n])
	}
	return out, nil
}

type memStore struct {
	chunks map[chunkstore.ChunkID][]byte
}

func newMemStore() *memStore {
	return &memStore{chunks: make(map[chunkstore.ChunkID][]byte)}
}

func (s *memStore) Put(buf []byte) (chunkstore.ChunkID, error) {
	id := chunkstore.ChunkID(blake3.Sum256(buf))
	cp := make([]byte, len(buf))
	copy(cp, buf)
	s.chunks[id] = cp
	return id, nil
}

func (s *memStore) Get(_ context.Context, id chunkstore.ChunkID) ([]byte, error) {
	b, ok := s.chunks[id]
	if !ok {
		return nil, chunkstore.ErrNotFound
	}
	return b, nil
}

func (s *memStore) Stat(id chunkstore.ChunkID) (chunkstore.ChunkMeta, bool) {
	b, ok := s.chunks[id]
	if !ok {
		return chunkstore.ChunkMeta{}, false
	}
	return chunkstore.ChunkMeta{LogicalLen: uint64(len(b)), StoredLen: uint64(len(b))}, true
}

func (s *memStore) GC(_ map[chunkstore.ChunkID]struct{}) (int, error) { return 0, nil }
func (s *memStore) Close() error                                      { return nil }

func putManifest(t *testing.T, store *memStore, m *voilapb.Manifest) chunkstore.ChunkID {
	t.Helper()
	data, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	id, err := store.Put(data)
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	return id
}

func filledChunk(fill byte) []byte {
	b := make([]byte, erofsadapter.ChunkSize)
	for i := range b {
		b[i] = fill
	}
	return b
}
