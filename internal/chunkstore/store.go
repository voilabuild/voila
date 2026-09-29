package chunkstore

import (
	"context"
	"encoding/hex"
	"errors"
)

// ChunkID is the BLAKE3 hash of the raw (uncompressed) chunk content.
type ChunkID [32]byte

// ErrNotFound is returned by Get when no chunk with the given id is present.
var ErrNotFound = errors.New("chunkstore: chunk not found")

// String returns the lowercase hex encoding of the id.
func (id ChunkID) String() string {
	var buf [64]byte
	hex.Encode(buf[:], id[:])
	return string(buf[:])
}

// ParseChunkID decodes a 64-char lowercase hex string into a ChunkID.
func ParseChunkID(s string) (ChunkID, error) {
	var id ChunkID
	if len(s) != 64 {
		return id, errors.New("chunkstore: invalid chunk id length")
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return id, err
	}
	copy(id[:], b)
	return id, nil
}

// ChunkMeta describes a stored chunk.
type ChunkMeta struct {
	LogicalLen uint64 // raw length
	StoredLen  uint64 // on-disk length (compressed or raw)
}

// ChunkStore is the content-addressed chunk storage interface.
type ChunkStore interface {
	Put(buf []byte) (ChunkID, error)                            // idempotent; always writes local
	Get(ctx context.Context, id ChunkID) ([]byte, error)        // returns RAW bytes; ErrNotFound if absent
	Stat(id ChunkID) (ChunkMeta, bool)                          // never triggers fetch
	GC(reachable map[ChunkID]struct{}) (removed int, err error) // mark-and-sweep
	Close() error
}

// StoredReader is an OPTIONAL capability a ChunkStore may implement: returning
// the on-disk (possibly compressed) bytes plus the compression algo, without
// decoding. `voila push` type-asserts to StoredReader so it can upload the
// stored-compressed form with a Content-Encoding header instead of
// round-tripping raw bytes that were stored compressed — a large bandwidth
// saving on compressible image layers. Stores that do NOT implement it fall
// back to the raw Get + PutChunk path.
type StoredReader interface {
	GetStored(id ChunkID) (stored []byte, algo int, err error)
}
