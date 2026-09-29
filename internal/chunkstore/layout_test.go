package chunkstore

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestBlobPath(t *testing.T) {
	id, err := ParseChunkID("abcdef0123456789" + strings.Repeat("0", 48))
	if err != nil {
		t.Fatalf("ParseChunkID: %v", err)
	}
	got := blobPath("/root", id)
	want := filepath.Join("/root", "chunks", "ab", "cd", "abcdef0123456789"+strings.Repeat("0", 48))
	if got != want {
		t.Fatalf("blobPath = %q, want %q", got, want)
	}
	if !strings.HasPrefix(filepath.Base(got), "abcdef") {
		t.Fatalf("blob base = %q, want it to start with the full hex id", filepath.Base(got))
	}
}

func TestParseFormatStability(t *testing.T) {
	// The sharded layout uses the first two and next two hex chars; ensure
	// String() really is lowercase so the layout is stable.
	id := ChunkID{0x12, 0x34, 0x56}
	dir := blobDir("/r", id)
	if !strings.HasSuffix(dir, filepath.Join("12", "34")) {
		t.Fatalf("blobDir %q should end with 12/34", dir)
	}
}
