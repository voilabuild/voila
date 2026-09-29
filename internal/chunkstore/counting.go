package chunkstore

import (
	"context"
	"sync"
)

// FetchStats is a point-in-time snapshot of what a CountingStore has served.
type FetchStats struct {
	// Chunks is the number of DISTINCT chunk ids fetched via Get.
	Chunks uint64
	// Bytes is the sum of the logical (uncompressed) lengths of those
	// distinct chunks. Repeat Gets of the same chunk count once.
	Bytes uint64
}

// CountingStore wraps a ChunkStore and records which distinct chunks flow
// through Get. It is the measurement seam for the "nothing is fetched unless
// touched" property: wrap the store handed to the mount daemon, run a
// container, snapshot Stats. In v0.1 a "fetch" is a local read; under the
// Phase 1 CachedStore the same wrapper measures cold-start network cost.
//
// Safe for concurrent use.
type CountingStore struct {
	inner ChunkStore

	mu    sync.Mutex
	seen  map[ChunkID]struct{}
	bytes uint64
}

// NewCounting wraps inner in a CountingStore with zeroed counters.
func NewCounting(inner ChunkStore) *CountingStore {
	return &CountingStore{inner: inner, seen: make(map[ChunkID]struct{})}
}

// Stats returns a snapshot of the counters.
func (c *CountingStore) Stats() FetchStats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return FetchStats{Chunks: uint64(len(c.seen)), Bytes: c.bytes}
}

// Get fetches from the inner store and, on success, records the chunk once.
func (c *CountingStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	b, err := c.inner.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	if _, ok := c.seen[id]; !ok {
		c.seen[id] = struct{}{}
		c.bytes += uint64(len(b))
	}
	c.mu.Unlock()
	return b, nil
}

// Put delegates; writes are not part of fetch accounting.
func (c *CountingStore) Put(buf []byte) (ChunkID, error) { return c.inner.Put(buf) }

// Stat delegates; Stat never fetches content (interface contract).
func (c *CountingStore) Stat(id ChunkID) (ChunkMeta, bool) { return c.inner.Stat(id) }

// GC delegates.
func (c *CountingStore) GC(reachable map[ChunkID]struct{}) (int, error) {
	return c.inner.GC(reachable)
}

// Close delegates. The inner store is typically shared (the daemon's global
// store); callers that do not own it should not Close through the wrapper.
func (c *CountingStore) Close() error { return c.inner.Close() }

var _ ChunkStore = (*CountingStore)(nil)
