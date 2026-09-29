package chunkstore

import (
	"context"
	"errors"
	"sync"
	"testing"
)

// fakeStore is a minimal in-memory ChunkStore for the counting tests. It
// serves Get out of a map keyed by ChunkID and records the byte lengths so
// the wrapper's Bytes accounting can be cross-checked against the payload
// sizes. Stat / GC / Close are no-ops (the CountingStore only routes Get
// through its accounting layer; the rest are pass-through).
type fakeStore struct {
	mu     sync.Mutex
	chunks map[ChunkID][]byte
	gets   int // total Get calls (for error-path assertions)
}

func newFakeStore() *fakeStore {
	return &fakeStore{chunks: map[ChunkID][]byte{}}
}

func (s *fakeStore) Put(buf []byte) (ChunkID, error) { return ChunkID{}, errors.New("not used") }

func (s *fakeStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.gets++
	b, ok := s.chunks[id]
	if !ok {
		return nil, ErrNotFound
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out, nil
}

func (s *fakeStore) Stat(id ChunkID) (ChunkMeta, bool)              { return ChunkMeta{}, false }
func (s *fakeStore) GC(reachable map[ChunkID]struct{}) (int, error) { return 0, nil }
func (s *fakeStore) Close() error                                   { return nil }

// putTestChunk inserts a chunk under id with payload b (so Get can later
// return it). Helper not part of the ChunkStore interface.
func (s *fakeStore) putTestChunk(id ChunkID, b []byte) {
	s.mu.Lock()
	s.chunks[id] = b
	s.mu.Unlock()
}

// TestCountingStore_DistinctCount verifies repeat Gets of the same ChunkID
// count once (Chunks = distinct ids, Bytes = sum of distinct payloads).
func TestCountingStore_DistinctCount(t *testing.T) {
	inner := newFakeStore()
	idA := ChunkID{0x01}
	idB := ChunkID{0x02}
	idC := ChunkID{0x03}
	inner.putTestChunk(idA, []byte("aaaa")) // 4 bytes
	inner.putTestChunk(idB, []byte("bb"))   // 2 bytes
	inner.putTestChunk(idC, []byte("ccc"))  // 3 bytes

	c := NewCounting(inner)
	ctx := context.Background()
	// Get A three times, B twice, C once.
	for _, id := range []ChunkID{idA, idA, idA, idB, idB, idC} {
		if _, err := c.Get(ctx, id); err != nil {
			t.Fatalf("Get %v: %v", id, err)
		}
	}
	st := c.Stats()
	if st.Chunks != 3 {
		t.Errorf("Chunks = %d, want 3 (distinct ids)", st.Chunks)
	}
	if st.Bytes != 9 {
		t.Errorf("Bytes = %d, want 9 (4+2+3)", st.Bytes)
	}
}

// TestCountingStore_ErrorGetNotCounted verifies a Get that returns
// ErrNotFound does not move the counters (neither Chunks nor Bytes).
func TestCountingStore_ErrorGetNotCounted(t *testing.T) {
	inner := newFakeStore()
	c := NewCounting(inner)
	missing := ChunkID{0xff}
	if _, err := c.Get(context.Background(), missing); err == nil {
		t.Fatal("expected ErrNotFound from fakeStore")
	}
	st := c.Stats()
	if st.Chunks != 0 || st.Bytes != 0 {
		t.Errorf("after error Get: stats = %+v, want all zero", st)
	}
	// A successful Get after the error still counts once, so the counters
	// did not get poisoned by the earlier error.
	id := ChunkID{0x42}
	inner.putTestChunk(id, []byte("hello"))
	if _, err := c.Get(context.Background(), id); err != nil {
		t.Fatalf("Get: %v", err)
	}
	st = c.Stats()
	if st.Chunks != 1 || st.Bytes != 5 {
		t.Errorf("after success: stats = %+v, want {1,5}", st)
	}
}

// TestCountingStore_StatsIsASnapshot verifies Stats returns a value copy:
// mutating the returned FetchStats does not affect the wrapper, and a
// subsequent Stats call reflects the live state, not the previously
// returned snapshot.
func TestCountingStore_StatsIsASnapshot(t *testing.T) {
	inner := newFakeStore()
	c := NewCounting(inner)
	id := ChunkID{0x10}
	inner.putTestChunk(id, []byte("x"))
	_, _ = c.Get(context.Background(), id)
	st := c.Stats()
	if st.Chunks != 1 {
		t.Fatalf("Chunks = %d", st.Chunks)
	}
	// Mutate the snapshot; the wrapper must be unaffected.
	st.Chunks = 999
	st.Bytes = 999
	st2 := c.Stats()
	if st2.Chunks != 1 || st2.Bytes != 1 {
		t.Errorf("after mutating snapshot: stats = %+v, want {1,1}", st2)
	}
}

// TestCountingStore_ConcurrentGetsRaceFree runs many concurrent Gets of a
// fixed small set of ids against the wrapper; under -race this would flag a
// data race in the accounting path. It also checks the final counters match
// the distinct-id set (no double-counting due to races).
func TestCountingStore_ConcurrentGetsRaceFree(t *testing.T) {
	inner := newFakeStore()
	ids := []ChunkID{
		{0x01}, {0x02}, {0x03}, {0x04}, {0x05},
		{0x06}, {0x07}, {0x08}, {0x09}, {0x0a},
	}
	for i, id := range ids {
		inner.putTestChunk(id, []byte{byte(i + 1)}) // 1 byte each
	}
	c := NewCounting(inner)
	const workers = 16
	const iters = 200
	var wg sync.WaitGroup
	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go func(seed int) {
			defer wg.Done()
			ctx := context.Background()
			for i := 0; i < iters; i++ {
				id := ids[(seed+i)%len(ids)]
				_, _ = c.Get(ctx, id)
				// Mix in concurrent Stats reads too (the snapshot path).
				if i%37 == 0 {
					_ = c.Stats()
				}
			}
		}(w)
	}
	wg.Wait()
	st := c.Stats()
	// All ids are eventually read; the distinct count must equal the set
	// size regardless of how many concurrent Get calls hit each id.
	if st.Chunks != uint64(len(ids)) {
		t.Errorf("Chunks = %d, want %d (distinct ids, race-free)", st.Chunks, len(ids))
	}
	if st.Bytes != uint64(len(ids)) { // every chunk payload is 1 byte
		t.Errorf("Bytes = %d, want %d", st.Bytes, len(ids))
	}
	if inner.gets != workers*iters {
		t.Errorf("inner store Get call count = %d, want %d (every Get must hit the inner store)", inner.gets, workers*iters)
	}
}

// TestCountingStore_DelegationNoClose verifies the wrapper routes Put / Stat
// / GC through to the inner store (the chunkstore.CountingStore contract:
// only Get is accounted). We assert the inner store received the calls by
// checking the returned values / panic-free behavior; Close is intentionally
// not exercised here since the inner store is a fake with no Close side
// effects.
func TestCountingStore_Delegation(t *testing.T) {
	inner := newFakeStore()
	c := NewCounting(inner)
	// Stat returns (zero, false) for the fake; just assert it does not
	// panic and the wrapper forwards it.
	if _, ok := c.Stat(ChunkID{0x01}); ok {
		t.Error("Stat should delegate to fakeStore's not-ok result")
	}
	// GC similarly forwards without error.
	if n, err := c.GC(nil); err != nil || n != 0 {
		t.Errorf("GC = (%d, %v), want (0, nil)", n, err)
	}
	// Close forwards; fakeStore.Close returns nil.
	if err := c.Close(); err != nil {
		t.Errorf("Close = %v, want nil", err)
	}
}
