package mount

import (
	"bytes"
	"context"
	"errors"
	"io"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"lukechampine.com/blake3"
)

// putChunk stores buf and returns the resulting chunk id.
func putChunk(t *testing.T, store *memStore, buf []byte) chunkstore.ChunkID {
	t.Helper()
	id, err := store.Put(buf)
	if err != nil {
		t.Fatalf("put chunk: %v", err)
	}
	return id
}

// chunkRef builds a *voilapb.Block referencing the chunk id of buf, anchored at
// offsetInFile and sized len(buf).
func chunkRef(t *testing.T, store *memStore, offsetInFile uint64, buf []byte) *voilapb.Block {
	t.Helper()
	id := putChunk(t, store, buf)
	return &voilapb.Block{
		OffsetInFile: offsetInFile,
		ChunkId:      append([]byte(nil), id[:]...),
		LogicalLen:   uint64(len(buf)),
	}
}

// holeRef returns a hole Block (chunk_id empty) at offsetInFile of length ln.
func holeRef(offsetInFile, ln uint64) *voilapb.Block {
	return &voilapb.Block{OffsetInFile: offsetInFile, LogicalLen: ln}
}

// makeFile assembles a *voilapb.File with the given blocks and explicit size.
func makeFile(size uint64, blocks ...*voilapb.Block) *voilapb.File {
	return &voilapb.File{Inode: 1, Mode: 0o644, Size: size, Blocks: blocks}
}

// readAll reads f fully via ReadAt, returning (bytes, err).
func readAll(ctx context.Context, store *memStore, f *voilapb.File) ([]byte, error) {
	dst := make([]byte, f.Size)
	n, err := ReadAt(ctx, store, f, dst, 0)
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return dst[:n], nil
}

func TestReadAt_MultiBlockCrossingBoundaries(t *testing.T) {
	store := newMemStore()
	mib := uint64(1) << 20
	// Three blocks of 1, 1, and 0.5 MiB, with distinct contents.
	b0 := bytes.Repeat([]byte("A"), int(mib))
	b1 := bytes.Repeat([]byte("B"), int(mib))
	b2 := bytes.Repeat([]byte("C"), int(mib/2))
	total := mib + mib + mib/2 // 2.5 MiB
	f := makeFile(total,
		chunkRef(t, store, 0, b0),
		chunkRef(t, store, mib, b1),
		chunkRef(t, store, 2*mib, b2),
	)
	ctx := context.Background()

	// Read 2 MiB starting at 0.5 MiB → straddles b0/b1 boundary and fully
	// covers b1, stops before b2.
	off := int64(mib / 2)
	dst := make([]byte, 2*mib)
	n, err := ReadAt(ctx, store, f, dst, off)
	if err != nil && !errors.Is(err, io.EOF) {
		t.Fatalf("ReadAt: %v", err)
	}
	if uint64(n) != 2*mib {
		t.Fatalf("ReadAt read %d bytes, want %d", n, 2*mib)
	}
	want := append(append([]byte(nil), b0[mib/2:]...), b1...)
	want = append(want, b2[:mib/2]...)
	if !bytes.Equal(dst[:n], want) {
		t.Fatalf("ReadAt content mismatch (len got=%d want=%d)", n, len(want))
	}

	// Full read.
	got, err := readAll(ctx, store, f)
	if err != nil {
		t.Fatalf("readAll: %v", err)
	}
	wantFull := append(append(b0, b1...), b2...)
	if !bytes.Equal(got, wantFull) {
		t.Fatalf("full read mismatch (got=%d want=%d)", len(got), len(wantFull))
	}
}

func TestReadAt_OffsetInsideBlock(t *testing.T) {
	store := newMemStore()
	body := []byte("0123456789ABCDEF")
	f := makeFile(uint64(len(body)), chunkRef(t, store, 0, body))

	dst := make([]byte, 4)
	n, err := ReadAt(context.Background(), store, f, dst, 5)
	if err != nil {
		t.Fatalf("ReadAt: %v", err)
	}
	if n != 4 {
		t.Fatalf("n=%d want 4", n)
	}
	if !bytes.Equal(dst[:n], []byte("5678")) {
		t.Fatalf("got %q want %q", dst[:n], "5678")
	}
}

func TestReadAt_HoleServesZeros(t *testing.T) {
	store := newMemStore()
	// File layout: 1 MiB real block, then a 1 MiB hole (chunk_id empty), then
	// a 1 MiB real block. Total 3 MiB.
	mib := 1 << 20
	real := bytes.Repeat([]byte("Z"), mib)
	f := makeFile(uint64(3*mib),
		chunkRef(t, store, 0, real),
		holeRef(uint64(mib), uint64(mib)),
		chunkRef(t, store, 2*uint64(mib), real),
	)
	got, err := readAll(context.Background(), store, f)
	if err != nil {
		t.Fatalf("readAll: %v", err)
	}
	want := make([]byte, 3*mib)
	copy(want[:mib], real)
	copy(want[2*mib:], real)
	if !bytes.Equal(got, want) {
		t.Fatalf("hole content mismatch (first diff in tail half)")
	}
}

func TestReadAt_GapBetweenBlocksServesZeros(t *testing.T) {
	store := newMemStore()
	// File claims 3 MiB but only has a block at [0,1 MiB) and another at
	// [2 MiB, 3 MiB). The [1 MiB, 2 MiB) gap must be zeros.
	mib := 1 << 20
	real := bytes.Repeat([]byte("Z"), mib)
	f := makeFile(uint64(3*mib),
		chunkRef(t, store, 0, real),
		chunkRef(t, store, 2*uint64(mib), real),
	)
	got, err := readAll(context.Background(), store, f)
	if err != nil {
		t.Fatalf("readAll: %v", err)
	}
	want := make([]byte, 3*mib)
	copy(want[:mib], real)
	copy(want[2*mib:], real)
	if !bytes.Equal(got, want) {
		t.Fatalf("content mismatch across inter-block gap")
	}
}

func TestReadAt_PastEOFReturnsEOF(t *testing.T) {
	store := newMemStore()
	body := []byte("hello")
	f := makeFile(uint64(len(body)), chunkRef(t, store, 0, body))

	// Read past EOF.
	dst := make([]byte, 8)
	n, err := ReadAt(context.Background(), store, f, dst, int64(len(body)))
	if n != 0 {
		t.Fatalf("past EOF n=%d want 0", n)
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("past EOF err=%v want io.EOF", err)
	}

	// Read that ends exactly at EOF returns (len, EOF).
	dst = make([]byte, len(body))
	n, err = ReadAt(context.Background(), store, f, dst, 0)
	if n != len(body) {
		t.Fatalf("at EOF n=%d want %d", n, len(body))
	}
	if !bytes.Equal(dst[:n], body) {
		t.Fatalf("body mismatch")
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("at EOF err=%v want io.EOF", err)
	}

	// Offset beyond EOF with empty file → still EOF.
	emptyF := makeFile(0)
	n, err = ReadAt(context.Background(), store, emptyF, dst, 0)
	if n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("empty file: n=%d err=%v want (0, io.EOF)", n, err)
	}
}

func TestReadAt_EmptyFileNoBlocks(t *testing.T) {
	store := newMemStore()
	f := makeFile(0)
	dst := make([]byte, 16)
	n, err := ReadAt(context.Background(), store, f, dst, 0)
	if n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("empty file with no blocks: n=%d err=%v want (0, io.EOF)", n, err)
	}
}

func TestReadAt_AllHoleFileServesZeros(t *testing.T) {
	store := newMemStore()
	f := makeFile(20, holeRef(0, 20))
	dst := make([]byte, 20)
	n, err := ReadAt(context.Background(), store, f, dst, 0)
	if n != 20 {
		t.Fatalf("all-hole n=%d want 20", n)
	}
	if !errors.Is(err, io.EOF) {
		t.Fatalf("all-hole err=%v want io.EOF", err)
	}
	for i, b := range dst {
		if b != 0 {
			t.Fatalf("dst[%d]=%d, want 0", i, b)
		}
	}
}

func TestReadAt_NilFileErrors(t *testing.T) {
	store := newMemStore()
	if _, err := ReadAt(context.Background(), store, nil, make([]byte, 4), 0); err == nil {
		t.Fatal("ReadAt on nil file should error")
	}
}

// Sanity: blake3 import path stays exercised so unused-import linters stay
// happy on incremental edits.
var _ = blake3.Sum256

// A FileReader must fetch each chunk from the store once when the kernel
// issues sequential sub-chunk read windows (the 8x-amplification regression).
func TestFileReader_CachesChunkAcrossSubChunkReads(t *testing.T) {
	store := newMemStore()
	const mib = 1 << 20
	b0 := bytes.Repeat([]byte{1}, mib)
	b1 := bytes.Repeat([]byte{2}, mib)
	f := &voilapb.File{
		Size:   2 * mib,
		Blocks: []*voilapb.Block{chunkRef(t, store, 0, b0), chunkRef(t, store, mib, b1)},
	}

	r := NewFileReader(store, f)
	base := store.GetCount()
	var got []byte
	dst := make([]byte, 128<<10) // kernel-style 128 KiB windows
	for off := int64(0); off < 2*mib; off += int64(len(dst)) {
		n, err := r.ReadAt(context.Background(), dst, off)
		if err != nil && err != io.EOF {
			t.Fatalf("ReadAt(%d): %v", off, err)
		}
		got = append(got, dst[:n]...)
	}
	if !bytes.Equal(got, append(append([]byte(nil), b0...), b1...)) {
		t.Fatalf("content mismatch (len=%d)", len(got))
	}
	if fetched := store.GetCount() - base; fetched != 2 {
		t.Fatalf("store.Get called %d times, want 2 (one per chunk)", fetched)
	}
}
