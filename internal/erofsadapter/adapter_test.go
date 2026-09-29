package erofsadapter

import (
	"context"
	"encoding/binary"
	"io/fs"
	"testing"

	"github.com/erofs/go-erofs"

	"voila/internal/chunkstore"
	"voila/internal/mount"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
	"lukechampine.com/blake3"
)

// memStore is an in-memory ChunkStore for tests.
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

// buildTestTree creates a small manifest tree:
//
//	/hello.txt   (1 MiB, one chunk)
//	/sub/        (dir)
//	/sub/big.txt (2 MiB, one chunk + one hole)
//	/link        (symlink → /hello.txt)
func buildTestTree(t *testing.T, store *memStore) chunkstore.ChunkID {
	t.Helper()
	// 1 MiB of content for hello.txt.
	content := make([]byte, ChunkSize)
	for i := range content {
		content[i] = byte(i)
	}
	cid1, err := store.Put(content)
	if err != nil {
		t.Fatalf("put hello content: %v", err)
	}

	// 1 MiB of content for the first block of big.txt.
	bigContent := make([]byte, ChunkSize)
	for i := range bigContent {
		bigContent[i] = byte(i + 1)
	}
	cid2, err := store.Put(bigContent)
	if err != nil {
		t.Fatalf("put big content: %v", err)
	}

	m := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{Inode: 1, Mode: 0o755, Uid: 0, Gid: 0, Entries: map[string]uint64{
				"hello.txt": 2,
				"sub":       3,
				"link":      4,
			}},
			{Inode: 3, Mode: 0o755, Uid: 0, Gid: 0, Entries: map[string]uint64{
				"big.txt": 5,
			}},
		},
		Files: map[uint64]*voilapb.File{
			2: {
				Inode: 2, Mode: 0o644, Uid: 1000, Gid: 1000, Size: ChunkSize,
				MtimeNs: 1_700_000_000_000_000_000,
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: cid1[:], LogicalLen: ChunkSize},
				},
			},
			5: {
				Inode: 5, Mode: 0o644, Uid: 0, Gid: 0, Size: 2 * ChunkSize,
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: cid2[:], LogicalLen: ChunkSize},
					{OffsetInFile: ChunkSize, ChunkId: nil, LogicalLen: ChunkSize}, // hole
				},
			},
		},
		Symlinks: map[uint64]*voilapb.Symlink{
			4: {Inode: 4, Target: "/hello.txt", Uid: 0, Gid: 0},
		},
	}
	return putManifest(t, store, m)
}

func TestBuildDeterministic(t *testing.T) {
	store := newMemStore()
	rootID := buildTestTree(t, store)

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	r1, err := Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build 1: %v", err)
	}

	// Rebuild with a fresh tree — must produce identical bytes.
	tree2, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load 2: %v", err)
	}
	r2, err := Build(ctx, tree2)
	if err != nil {
		t.Fatalf("Build 2: %v", err)
	}

	if len(r1.Metadata) != len(r2.Metadata) {
		t.Fatalf("metadata size differs: %d vs %d", len(r1.Metadata), len(r2.Metadata))
	}
	for i := range r1.Metadata {
		if r1.Metadata[i] != r2.Metadata[i] {
			t.Fatalf("metadata differs at byte %d: %d vs %d", i, r1.Metadata[i], r2.Metadata[i])
		}
	}
}

func TestBuildSlotTable(t *testing.T) {
	store := newMemStore()
	rootID := buildTestTree(t, store)

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	r, err := Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	// We have 2 unique non-hole chunks (hello.txt's chunk and big.txt's first chunk).
	if len(r.SlotTable) != 2 {
		t.Fatalf("SlotTable len = %d, want 2", len(r.SlotTable))
	}

	// Device size = metadata (padded to block) + 2 * 1 MiB.
	if r.DataOffset <= 0 {
		t.Fatalf("DataOffset = %d, want > 0", r.DataOffset)
	}
	expectedSize := r.DataOffset + int64(len(r.SlotTable))*ChunkSize
	if r.DeviceSize != expectedSize {
		t.Fatalf("DeviceSize = %d, want %d", r.DeviceSize, expectedSize)
	}

	// hello.txt (inode 2) has 1 slot.
	if slots, ok := r.FileSlots[2]; !ok || len(slots) != 1 {
		t.Fatalf("FileSlots[2] = %v, want 1 slot", slots)
	}
	// big.txt (inode 5) has 1 slot (the hole doesn't get a slot).
	if slots, ok := r.FileSlots[5]; !ok || len(slots) != 1 {
		t.Fatalf("FileSlots[5] = %v, want 1 slot", slots)
	}
}

// buildNonAdjacentTree creates:
//
//	/a.bin (1 MiB, chunk A) → slot 0
//	/b.bin (1 MiB, chunk B) → slot 1
//	/c.bin (2 MiB, chunk A + chunk C) → slots 0, 2 (not adjacent)
//
// /c.bin is the case that makes go-erofs set chunkBits=0.
func buildNonAdjacentTree(t *testing.T, store *memStore) chunkstore.ChunkID {
	t.Helper()
	chunkA := filledChunk(0xAA)
	chunkB := filledChunk(0xBB)
	chunkC := filledChunk(0xCC)
	idA, err := store.Put(chunkA)
	if err != nil {
		t.Fatalf("put A: %v", err)
	}
	idB, err := store.Put(chunkB)
	if err != nil {
		t.Fatalf("put B: %v", err)
	}
	idC, err := store.Put(chunkC)
	if err != nil {
		t.Fatalf("put C: %v", err)
	}

	m := &voilapb.Manifest{
		Dirs: []*voilapb.Dir{
			{Inode: 1, Mode: 0o755, Entries: map[string]uint64{
				"a.bin": 2,
				"b.bin": 3,
				"c.bin": 4,
			}},
		},
		Files: map[uint64]*voilapb.File{
			2: {
				Inode: 2, Mode: 0o644, Size: ChunkSize,
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: idA[:], LogicalLen: ChunkSize},
				},
			},
			3: {
				Inode: 3, Mode: 0o644, Size: ChunkSize,
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: idB[:], LogicalLen: ChunkSize},
				},
			},
			4: {
				Inode: 4, Mode: 0o644, Size: 2 * ChunkSize,
				Blocks: []*voilapb.Block{
					{OffsetInFile: 0, ChunkId: idA[:], LogicalLen: ChunkSize},
					{OffsetInFile: ChunkSize, ChunkId: idC[:], LogicalLen: ChunkSize},
				},
			},
		},
	}
	return putManifest(t, store, m)
}

func filledChunk(fill byte) []byte {
	b := make([]byte, ChunkSize)
	for i := range b {
		b[i] = fill
	}
	return b
}

func TestBuildForces1MiBChunks(t *testing.T) {
	store := newMemStore()
	rootID := buildNonAdjacentTree(t, store)

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	r, err := Build(ctx, tree)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}

	infos := dumpChunkInodes(t, r.Metadata)
	c, ok := infos["c.bin"]
	if !ok {
		t.Fatalf("c.bin not found in image; files = %v", keys(infos))
	}
	if c.chunkBits < 8 {
		t.Fatalf("c.bin chunkBits = %d, want >= 8 (1 MiB)", c.chunkBits)
	}
	if c.nchunks != 2 {
		t.Fatalf("c.bin nchunks = %d, want 2", c.nchunks)
	}
	// Slots 0 and 2: startblks should be 256 blocks (1 MiB) apart, not 1.
	if c.startblks[1] <= c.startblks[0] {
		t.Fatalf("c.bin startblks = %v, want increasing", c.startblks)
	}
	gap := c.startblks[1] - c.startblks[0]
	if gap != 512 { // slot 2 - slot 0 = 2 MiB = 512 blocks
		t.Fatalf("c.bin startblk gap = %d, want 512 (non-adjacent slots 0 and 2)", gap)
	}

	// Every chunk-based file must use at least 1 MiB chunks.
	for name, in := range infos {
		if in.chunkBits < 8 {
			t.Errorf("%s: chunkBits = %d, want >= 8", name, in.chunkBits)
		}
	}

	// big.txt in the standard tree is 2 MiB with a hole in the second slot.
	rootID2 := buildTestTree(t, store)
	tree2, err := mount.Load(ctx, store, rootID2)
	if err != nil {
		t.Fatalf("Load 2: %v", err)
	}
	r2, err := Build(ctx, tree2)
	if err != nil {
		t.Fatalf("Build 2: %v", err)
	}
	infos2 := dumpChunkInodes(t, r2.Metadata)
	big, ok := infos2["sub/big.txt"]
	if !ok {
		t.Fatalf("sub/big.txt not found; files = %v", keys(infos2))
	}
	if big.chunkBits < 8 {
		t.Fatalf("big.txt chunkBits = %d, want >= 8", big.chunkBits)
	}
	if big.nchunks != 2 {
		t.Fatalf("big.txt nchunks = %d, want 2", big.nchunks)
	}
	if !big.nulls[1] {
		t.Fatalf("big.txt chunk[1] should be a hole, startblks=%v nulls=%v", big.startblks, big.nulls)
	}
}

type chunkInodeInfo struct {
	chunkBits uint32
	nchunks   int
	startblks []uint32
	nulls     []bool
}

func dumpChunkInodes(t *testing.T, image []byte) map[string]chunkInodeInfo {
	t.Helper()
	imgFS, err := erofs.Open(bytesReaderAt(image))
	if err != nil {
		t.Fatalf("erofs.Open: %v", err)
	}
	sb := image[sbOffset:]
	blockSize := int(1) << sb[12]
	metaBlkAddr := binary.LittleEndian.Uint32(sb[40:44])
	metaStart := int64(metaBlkAddr) * int64(blockSize)

	out := make(map[string]chunkInodeInfo)
	err = fs.WalkDir(imgFS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || p == "." {
			return nil
		}
		f, err := imgFS.Open(p)
		if err != nil {
			return nil
		}
		info, err := f.Stat()
		_ = f.Close()
		if err != nil {
			return nil
		}
		st, ok := info.Sys().(*erofs.Stat)
		if !ok {
			return nil
		}
		iloc := metaStart + st.Ino*inodeCompact
		if iloc+inodeCompact > int64(len(image)) {
			return nil
		}
		iFormat := binary.LittleEndian.Uint16(image[iloc : iloc+2])
		if (iFormat>>iDatalayoutBit)&0x07 != layoutChunkBased {
			return nil
		}
		xattrCount := binary.LittleEndian.Uint16(image[iloc+2 : iloc+4])
		xattrSize := 0
		if xattrCount > 0 {
			xattrSize = 12 + 4*(int(xattrCount)-1)
		}
		inodeSize := inodeCompact
		if iFormat&(1<<iVersionBit) != 0 {
			inodeSize = inodeExtended
		}
		chunkIdxStart := iloc + int64(inodeSize) + int64(xattrSize)
		if rem := chunkIdxStart % 8; rem != 0 {
			chunkIdxStart += 8 - rem
		}
		iU := binary.LittleEndian.Uint32(image[iloc+16 : iloc+20])
		chunkBits := iU & 0x1f
		chunkSize := int64(blockSize) << chunkBits
		nchunks := int((info.Size() + chunkSize - 1) / chunkSize)
		ci := chunkInodeInfo{chunkBits: chunkBits, nchunks: nchunks}
		for i := 0; i < nchunks; i++ {
			off := chunkIdxStart + int64(i)*chunkIndexSize
			if off+chunkIndexSize > int64(len(image)) {
				break
			}
			idx := image[off : off+chunkIndexSize]
			null := isNullChunkIndex(idx)
			ci.nulls = append(ci.nulls, null)
			ci.startblks = append(ci.startblks, binary.LittleEndian.Uint32(idx[4:8]))
		}
		out[p] = ci
		return nil
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
	return out
}

func TestSeekBufferManySmallWrites(t *testing.T) {
	var s seekBuffer
	const n = 256 * 1024
	p := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	for i := 0; i < n; i++ {
		if _, err := s.Write(p); err != nil {
			t.Fatal(err)
		}
	}
	if len(s.Bytes()) != n*len(p) {
		t.Fatalf("len=%d, want %d", len(s.Bytes()), n*len(p))
	}
	// Overwrite after seek (go-erofs superblock rewrite).
	if _, err := s.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Write([]byte("EROS")); err != nil {
		t.Fatal(err)
	}
	got := s.Bytes()
	if string(got[:4]) != "EROS" {
		t.Fatalf("seek+overwrite: %q", got[:4])
	}
	if len(got) != n*len(p) {
		t.Fatalf("len after overwrite=%d, want %d", len(got), n*len(p))
	}
}

func keys(m map[string]chunkInodeInfo) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
