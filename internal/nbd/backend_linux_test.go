//go:build linux

package nbd

import (
	"context"
	"os"
	"testing"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
)

func TestAcquire_ReadyWithoutSleep(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root")
	}
	if _, err := os.Stat("/dev/nbd0"); err != nil {
		t.Skip("requires /dev/nbd0")
	}
	store := newMemStore()
	meta := make([]byte, 4096)
	result := &erofsadapter.BuildResult{
		Metadata:   meta,
		DataOffset: 4096,
		DeviceSize: 4096,
	}
	ctx := context.Background()
	reg := NewRegistry()
	t0 := time.Now()
	dev, err := reg.Acquire(ctx, "ready-test", result, store)
	elapsed := time.Since(t0)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer reg.Release("ready-test")
	if _, err := os.ReadFile("/sys/block/" + dev.Path()[len("/dev/"):] + "/pid"); err != nil {
		t.Fatalf("device not connected: %v", err)
	}
	// The old path slept 150ms unconditionally. Ready-wait should land well under that.
	if elapsed > 80*time.Millisecond {
		t.Fatalf("Acquire took %s; hardcoded sleeps may be back", elapsed)
	}
}

func TestChunkBackend_ReadAtSpansSlots(t *testing.T) {
	store := newMemStore()
	a := filledChunk(0xAA)
	c := filledChunk(0xCC)
	idA, _ := store.Put(a)
	idC, _ := store.Put(c)

	meta := []byte("EROFS-META")
	dataOffset := int64(4096)
	b := newChunkBackend(&erofsadapter.BuildResult{
		Metadata:   append(append([]byte{}, meta...), make([]byte, dataOffset-int64(len(meta)))...),
		DataOffset: dataOffset,
		SlotTable:  []chunkstore.ChunkID{idA, idC},
		DeviceSize: dataOffset + 2*erofsadapter.ChunkSize,
	}, store)

	// Read 8 bytes that straddle the 1 MiB slot boundary.
	buf := make([]byte, 8)
	off := dataOffset + erofsadapter.ChunkSize - 4
	n, err := b.ReadAt(buf, off)
	if err != nil {
		t.Fatalf("ReadAt: %v", err)
	}
	if n != 8 {
		t.Fatalf("ReadAt n=%d, want 8", n)
	}
	for i := 0; i < 4; i++ {
		if buf[i] != 0xAA {
			t.Fatalf("buf[%d]=0x%02x, want 0xAA (end of slot 0)", i, buf[i])
		}
	}
	for i := 4; i < 8; i++ {
		if buf[i] != 0xCC {
			t.Fatalf("buf[%d]=0x%02x, want 0xCC (start of slot 1) — ReadAt must walk slots", i, buf[i])
		}
	}

	// One large read covering both slots (the postgres / minChunkBits case).
	big := make([]byte, 2*erofsadapter.ChunkSize)
	n, err = b.ReadAt(big, dataOffset)
	if err != nil {
		t.Fatalf("ReadAt big: %v", err)
	}
	if n != len(big) {
		t.Fatalf("ReadAt big n=%d, want %d", n, len(big))
	}
	if big[0] != 0xAA || big[erofsadapter.ChunkSize-1] != 0xAA {
		t.Fatalf("slot 0 not served in large read")
	}
	if big[erofsadapter.ChunkSize] != 0xCC || big[len(big)-1] != 0xCC {
		t.Fatalf("slot 1 zero-filled in large read (the SIGILL bug)")
	}
}

func TestChunkBackend_ReadAtSpansMetadata(t *testing.T) {
	store := newMemStore()
	a := filledChunk(0xAA)
	idA, _ := store.Put(a)
	meta := make([]byte, 4096)
	for i := range meta {
		meta[i] = 0x11
	}
	b := newChunkBackend(&erofsadapter.BuildResult{
		Metadata:   meta,
		DataOffset: 4096,
		SlotTable:  []chunkstore.ChunkID{idA},
		DeviceSize: 4096 + erofsadapter.ChunkSize,
	}, store)

	buf := make([]byte, 16)
	n, err := b.ReadAt(buf, 4096-8)
	if err != nil {
		t.Fatalf("ReadAt: %v", err)
	}
	if n != 16 {
		t.Fatalf("n=%d, want 16", n)
	}
	for i := 0; i < 8; i++ {
		if buf[i] != 0x11 {
			t.Fatalf("buf[%d]=0x%02x, want 0x11 (metadata)", i, buf[i])
		}
	}
	for i := 8; i < 16; i++ {
		if buf[i] != 0xAA {
			t.Fatalf("buf[%d]=0x%02x, want 0xAA (first data slot)", i, buf[i])
		}
	}
}
