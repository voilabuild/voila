// cached.go implements CachedStore: a ChunkStore whose Get transparently
// fetches missing chunks from a remote Fetcher (the registry Client) and
// writes them through to the local store, so subsequent calls are local
// hits. Put / Stat / GC / Close delegate to the local store and never
// trigger a fetch (publishing to a registry is explicit via `voila push`).
//
// The seam is the Fetcher interface (defined in this package so chunkstore
// depends on neither registry nor proto): the registry Client implements
// Fetcher by being passed into NewCached; chunkstore has no knowledge of
// HTTP. This is the Phase 1 LRU / lazy-streaming story of plan §4.3 — a
// fresh machine running `voila run <ref>` pulls only the chunks its
// process actually touches.
package chunkstore

import (
	"context"
	"errors"
	"fmt"

	"lukechampine.com/blake3"
)

// Fetcher fetches a chunk's raw bytes from a remote source. The registry
// Client implements Fetcher. GetChunk returns an error wrapping ErrNotFound
// when the remote does not have the chunk; any other error is a transport
// or integrity failure.
type Fetcher interface {
	GetChunk(ctx context.Context, id ChunkID) ([]byte, error)
}

// CachedStore wraps a local ChunkStore with a remote Fetcher. Get is local
// first; on ErrNotFound it fetches from the remote, verifies the bytes
// (BLAKE3 must equal id), writes them through to the local store, and
// returns. Subsequent Gets of the same chunk hit the local store and never
// touch the remote.
//
// CachedStore does not provide its own eviction: the local store's GC owns
// that, and the Phase 1 story (plan §4.3) is that re-fetchable chunks can be
// safely deleted. CachedStore therefore delegates GC unchanged.
//
// Safe for concurrent use; the local store must itself be safe (LocalStore
// is). Concurrent Gets of the same missing id will each fetch and write the
// chunk once; the writes are idempotent.
type CachedStore struct {
	local  ChunkStore
	remote Fetcher
}

// NewCached returns a CachedStore backed by local (the cache) and remote
// (the source of misses). Neither may be nil.
func NewCached(local ChunkStore, remote Fetcher) *CachedStore {
	if local == nil {
		panic("chunkstore: NewCached with nil local store")
	}
	if remote == nil {
		panic("chunkstore: NewCached with nil remote Fetcher")
	}
	return &CachedStore{local: local, remote: remote}
}

// Get returns the raw bytes for id, fetching from the remote on a local miss
// and writing through to the local store. The remote bytes are integrity-
// checked: BLAKE3(raw) must equal id, otherwise the chunk is rejected and
// NOT cached (returning an integrity error). A remote miss surfaces as
// ErrNotFound.
func (c *CachedStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	data, err := c.local.Get(ctx, id)
	if err == nil {
		return data, nil
	}
	if !errors.Is(err, ErrNotFound) {
		// Other local errors (corrupt blob, I/O) propagate — do not paper
		// over a broken cache with a remote fetch.
		return nil, err
	}
	remote, rerr := c.remote.GetChunk(ctx, id)
	if rerr != nil {
		if errors.Is(rerr, ErrNotFound) {
			return nil, fmt.Errorf("chunk %s: %w", id, ErrNotFound)
		}
		return nil, fmt.Errorf("chunkstore: fetch %s: %w", id, rerr)
	}
	// Integrity check on the bytes we received over the network. A
	// hash mismatch is corruption; we refuse to cache it.
	got := ChunkID(blake3.Sum256(remote))
	if got != id {
		return nil, fmt.Errorf("chunkstore: remote chunk %s integrity failure (BLAKE3 mismatch)", id)
	}
	// Write-through to the local cache. Put is idempotent; a concurrent
	// write of the same bytes is harmless (it returns the existing id).
	if _, werr := c.local.Put(remote); werr != nil {
		return nil, fmt.Errorf("chunkstore: cache %s: %w", id, werr)
	}
	return remote, nil
}

// Put delegates to the local store. Publishing to a registry is explicit
// (`voila push`); CachedStore does not auto-upload.
func (c *CachedStore) Put(buf []byte) (ChunkID, error) { return c.local.Put(buf) }

// Stat delegates to the local store. Stat never triggers a fetch (interface
// contract); a chunk present remotely but not locally is reported as absent.
func (c *CachedStore) Stat(id ChunkID) (ChunkMeta, bool) { return c.local.Stat(id) }

// GC delegates to the local store. Re-fetchable chunks may be deleted; see
// plan §4.3.
func (c *CachedStore) GC(reachable map[ChunkID]struct{}) (int, error) {
	return c.local.GC(reachable)
}

// Close delegates to the local store. The remote Fetcher owns its own
// lifetime (the registry Client.Close closes the underlying HTTP transport
// — callers wiring a CachedStore own both halves and close them separately).
func (c *CachedStore) Close() error { return c.local.Close() }

var _ ChunkStore = (*CachedStore)(nil)
