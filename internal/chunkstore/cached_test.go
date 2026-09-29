package chunkstore

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"

	"lukechampine.com/blake3"
)

// fakeFetcher is a programmable Fetcher used by CachedStore tests. It
// records how many times GetChunk was called (per id, for the "local hit
// never calls remote" test) and can serve either canned bytes, an ErrNotFound,
// or arbitrary corruption (bytes that do NOT hash to the requested id) so the
// integrity path is exercised.
type fakeFetcher struct {
	mu       sync.Mutex
	getCalls map[ChunkID]int

	// calls is the per-id call count for the convenience of assertions that
	// inspect totals.
	calls int32

	// serve, if set, returns (bytes, ok). ok=false → ErrNotFound.
	serve func(id ChunkID) ([]byte, bool)
	// corrupt, if true, returns bytes that do NOT match id (integrity failure).
	corrupt bool
}

func newFakeFetcher() *fakeFetcher {
	return &fakeFetcher{getCalls: map[ChunkID]int{}}
}

func (f *fakeFetcher) GetChunk(ctx context.Context, id ChunkID) ([]byte, error) {
	f.mu.Lock()
	f.getCalls[id]++
	f.mu.Unlock()
	atomic.AddInt32(&f.calls, 1)
	if f.serve == nil {
		return nil, fmt.Errorf("%w: chunk %s", ErrNotFound, id)
	}
	b, ok := f.serve(id)
	if !ok {
		return nil, fmt.Errorf("%w: chunk %s", ErrNotFound, id)
	}
	if f.corrupt {
		// Mutate so the BLAKE3 no longer matches id but the response is
		// still "some bytes". (Caller picked b to be the real id's bytes;
		// flipping one byte makes it corrupt.)
		out := make([]byte, len(b))
		copy(out, b)
		if len(out) > 0 {
			out[0] ^= 0xff
		}
		return out, nil
	}
	return b, nil
}

// TestCachedStore_LocalHitNeverCallsRemote verifies that a Get for a chunk
// already in the local store resolves locally and never touches the remote.
func TestCachedStore_LocalHitNeverCallsRemote(t *testing.T) {
	local := newTestStore(t)
	const payload = "cached local hit"
	id, err := local.Put([]byte(payload))
	if err != nil {
		t.Fatalf("Put: %v", err)
	}
	var remoteCalls int32
	fetcher := newFakeFetcher()
	fetcher.serve = func(req ChunkID) ([]byte, bool) {
		atomic.AddInt32(&remoteCalls, 1)
		return nil, false
	}
	c := NewCached(local, fetcher)

	got, err := c.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(got) != payload {
		t.Fatalf("Get returned %q, want %q", got, payload)
	}
	if remoteCalls != 0 {
		t.Fatalf("remote called %d time(s) on a local hit; want 0", remoteCalls)
	}
	if fetcher.getCalls[id] != 0 {
		t.Fatalf("fetcher recorded %d call(s) for %s; want 0", fetcher.getCalls[id], id)
	}
}

// TestCachedStore_MissFetchesRemoteAndWritesThrough asserts the write-through
// path: a miss → remote GetChunk → verify → local Put; the second Get for
// the same id is a local hit (no further remote calls).
func TestCachedStore_MissFetchesRemoteAndWritesThrough(t *testing.T) {
	local := newTestStore(t)
	fetcher := newFakeFetcher()
	var payload = []byte("write me through")
	id := ChunkID(blake3Sum(payload))
	fetcher.serve = func(req ChunkID) ([]byte, bool) {
		if req != id {
			t.Errorf("remote asked for %s, want %s", req, id)
			return nil, false
		}
		return payload, true
	}
	c := NewCached(local, fetcher)

	// Chunk must be absent locally before the first Get.
	if _, ok := local.Stat(id); ok {
		t.Fatal("chunk already present locally before Get")
	}

	got, err := c.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("Get = %q, want %q", got, payload)
	}
	// After write-through, the chunk must be locally present (Stat, and a
	// direct local Get both succeed without touching the remote).
	if _, ok := local.Stat(id); !ok {
		t.Fatal("chunk not cached locally after remote fetch")
	}
	if fetcher.getCalls[id] != 1 {
		t.Fatalf("remote called %d time(s), want 1", fetcher.getCalls[id])
	}
	// Disable the remote fetcher entirely; the second Get MUST be a local
	// hit and MUST NOT call the remote.
	fetcher.serve = func(req ChunkID) ([]byte, bool) {
		t.Errorf("remote called on a cache hit for %s", req)
		return nil, false
	}
	got2, err := c.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("second Get: %v", err)
	}
	if !bytes.Equal(got2, payload) {
		t.Fatalf("second Get = %q, want %q", got2, payload)
	}
}

// TestCachedStore_RemoteCorruptBytesRejectedNotCached: if the remote returns
// bytes whose BLAKE3 does not equal id, CachedStore MUST reject them and NOT
// cache garbage in the local store.
func TestCachedStore_RemoteCorruptBytesRejectedNotCached(t *testing.T) {
	local := newTestStore(t)
	var payload = []byte("the real bytes")
	id := ChunkID(blake3Sum(payload))
	fetcher := newFakeFetcher()
	fetcher.serve = func(req ChunkID) ([]byte, bool) { return payload, true }
	fetcher.corrupt = true
	c := NewCached(local, fetcher)

	_, err := c.Get(context.Background(), id)
	if err == nil {
		t.Fatal("expected integrity error from corrupt remote, got nil")
	}
	if !contains(err.Error(), "integrity") {
		t.Errorf("error %q should mention integrity", err.Error())
	}
	// Crucially: nothing must have been cached.
	if _, ok := local.Stat(id); ok {
		t.Fatal("corrupt chunk was cached locally; must not be cached")
	}
}

// TestCachedStore_RemoteMissIsNotFound: when both local and remote miss,
// CachedStore returns an error wrapping ErrNotFound.
func TestCachedStore_RemoteMissIsNotFound(t *testing.T) {
	local := newTestStore(t)
	fetcher := newFakeFetcher() // serve==nil → 404
	c := NewCached(local, fetcher)
	var id ChunkID
	id[0] = 0x42
	_, err := c.Get(context.Background(), id)
	if err == nil {
		t.Fatal("expected ErrNotFound, got nil")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want errors.Is ErrNotFound", err)
	}
}

// TestCachedStore_ConcurrentMissesSameChunk exercises the concurrent-write
// race: several goroutines Get the same missing id; each may trigger a
// remote fetch + a local write, but the writes must be idempotent and the
// final local store must contain exactly one copy of the chunk.
func TestCachedStore_ConcurrentMissesSameChunk(t *testing.T) {
	local := newTestStore(t)
	var payload = bytes.Repeat([]byte("concurrent miss "), 32)
	id := ChunkID(blake3Sum(payload))
	fetcher := newFakeFetcher()
	fetcher.serve = func(_ ChunkID) ([]byte, bool) { return payload, true }
	c := NewCached(local, fetcher)

	const goroutines = 16
	var wg sync.WaitGroup
	wg.Add(goroutines)
	errs := make(chan error, goroutines)
	for i := 0; i < goroutines; i++ {
		go func() {
			defer wg.Done()
			got, err := c.Get(context.Background(), id)
			if err != nil {
				errs <- err
				return
			}
			if !bytes.Equal(got, payload) {
				errs <- fmt.Errorf("Get mismatch (len %d vs %d)", len(got), len(payload))
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent Get: %v", err)
	}
	got, err := local.Get(context.Background(), id)
	if err != nil {
		t.Fatalf("post-concurrency local Get: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("local chunk differs from payload after concurrent write-through")
	}
}

// blake3Sum is a tiny helper mirroring LocalStore.hash, expressed here so the
// tests do not depend on an unexported symbol. Must match LocalStore.hash.
func blake3Sum(b []byte) [32]byte { return blake3.Sum256(b) }
