//go:build zig_nbd_fixture

// Writes the on-disk fixture for poc/zig-nbd (see README).
//
//	go run -tags zig_nbd_fixture ./poc/zig-nbd/fixture -o /tmp/zig-nbd-fixture
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"lukechampine.com/blake3"
	"google.golang.org/protobuf/proto"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
	"voila/internal/mount"
	voilapb "voila/internal/proto"
)

func main() {
	out := flag.String("o", "fixture-out", "output directory")
	flag.Parse()

	if err := writeFixture(*out); err != nil {
		fmt.Fprintf(os.Stderr, "write fixture: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "wrote fixture to %s\n", *out)
}

func writeFixture(dir string) error {
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
	rootID := putManifest(store, m)

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootID)
	if err != nil {
		return fmt.Errorf("Load: %w", err)
	}
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		return fmt.Errorf("Build: %w", err)
	}

	if err := os.MkdirAll(filepath.Join(dir, "chunks"), 0o755); err != nil {
		return err
	}

	chunkBytes := map[chunkstore.ChunkID][]byte{
		idA: chunkA,
		idB: chunkB,
		idC: chunkC,
	}
	written := make(map[chunkstore.ChunkID]bool)
	for _, cid := range result.SlotTable {
		if cid == (chunkstore.ChunkID{}) || written[cid] {
			continue
		}
		written[cid] = true
		data := chunkBytes[cid]
		if data == nil {
			return fmt.Errorf("missing chunk bytes for %s", cid.String())
		}
		path := filepath.Join(dir, "chunks", cid.String())
		if err := os.WriteFile(path, data, 0o644); err != nil {
			return err
		}
	}

	var slots strings.Builder
	for i, cid := range result.SlotTable {
		name := ""
		if cid != (chunkstore.ChunkID{}) {
			name = cid.String()
		}
		fmt.Fprintf(&slots, "%d %s\n", i, name)
	}

	if err := os.WriteFile(filepath.Join(dir, "meta.bin"), result.Metadata, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "slots.txt"), []byte(slots.String()), 0o644); err != nil {
		return err
	}
	return nil
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

func putManifest(store *memStore, m *voilapb.Manifest) chunkstore.ChunkID {
	data, err := proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, m)
	if err != nil {
		panic(err)
	}
	id, err := store.Put(data)
	if err != nil {
		panic(err)
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
