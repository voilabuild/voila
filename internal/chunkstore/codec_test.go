package chunkstore

import (
	"strings"
	"testing"
)

func TestParseRoundtrip(t *testing.T) {
	id := ChunkID{0xab, 0xcd, 0xef, 0x01, 0x23, 0x45}
	s := id.String()
	if len(s) != 64 {
		t.Fatalf("String length = %d, want 64", len(s))
	}
	if s[0] != 'a' || s[1] != 'b' {
		t.Fatalf("first two hex chars = %q, want ab", s[:2])
	}
	got, err := ParseChunkID(s)
	if err != nil {
		t.Fatalf("ParseChunkID: %v", err)
	}
	if got != id {
		t.Fatalf("parsed id = %v, want %v", got, id)
	}
}

func TestParseInvalid(t *testing.T) {
	if _, err := ParseChunkID("abc"); err == nil {
		t.Fatal("expected error for short input")
	}
	if _, err := ParseChunkID(strings.Repeat("z", 64)); err == nil {
		t.Fatal("expected error for non-hex input")
	}
}

// repeat returns n copies of the byte c as a slice.
func repeat(c byte, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = c
	}
	return b
}

func TestEncodeDecodeRawSmall(t *testing.T) {
	buf := repeat('x', 100)
	stored, algo := encode(buf)
	if algo != compRaw {
		t.Fatalf("algo = %d, want compRaw", algo)
	}
	out, err := decode(stored, algo)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(out) != string(buf) {
		t.Fatal("roundtrip mismatch")
	}
}

func TestEncodeDecodeCompressible(t *testing.T) {
	buf := repeat('a', 1<<20) // 1 MiB of repeated bytes
	stored, algo := encode(buf)
	if algo != compZstd {
		t.Fatalf("algo = %d, want compZstd", algo)
	}
	if len(stored) >= len(buf) {
		t.Fatalf("stored len = %d, want < %d", len(stored), len(buf))
	}
	out, err := decode(stored, algo)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(out) != string(buf) {
		t.Fatal("roundtrip mismatch")
	}
}

func TestEncodeDecodeIncompressible(t *testing.T) {
	rng := newRand(1 << 17)
	buf := make([]byte, 1<<17)
	for i := range buf {
		buf[i] = byte(rng())
	}
	stored, algo := encode(buf)
	if algo != compRaw {
		t.Fatalf("algo = %d, want compRaw", algo)
	}
	if len(stored) != len(buf) {
		t.Fatalf("stored len = %d, want raw = %d", len(stored), len(buf))
	}
	out, err := decode(stored, algo)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(out) != string(buf) {
		t.Fatal("roundtrip mismatch")
	}
}

// newRand returns a deterministic xorshift PRNG producing ints in [0,256).
func newRand(seed uint64) func() int {
	state := seed | 1
	return func() int {
		state ^= state << 13
		state ^= state >> 7
		state ^= state << 17
		return int(state & 0xff)
	}
}
