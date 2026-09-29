package worker

import (
	"bytes"
	"fmt"
	"math/rand"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestRing_EvictionOrder verifies evict-oldest-whole-chunk keeps the most
// recent data inside budget while older chunks are dropped.
func TestRing_EvictionOrder(t *testing.T) {
	r := newRing(100) // tiny budget

	for i := 0; i < 5; i++ {
		// 30 bytes each — after the 4th chunk size = 120 > 100, so the
		// oldest (i=0) is evicted; after the 5th, i=0 and i=1 are evicted.
		r.append([]byte(fmt.Sprintf("chunk-%02d-aaaaaaaaaaaaaaaaa", i)), false, 0)
	}
	got := r.replay()
	want := []string{"chunk-02-aaaaaaaaaaaaaaaaa", "chunk-03-aaaaaaaaaaaaaaaaa", "chunk-04-aaaaaaaaaaaaaaaaa"}
	if len(got) != len(want) {
		t.Fatalf("got %d chunks %q, want %d", len(got), chunksToString(got), len(want))
	}
	for i, c := range got {
		if string(c.data) != want[i] {
			t.Errorf("chunk[%d] = %q, want %q", i, string(c.data), want[i])
		}
	}
	if r.size > r.budget {
		t.Errorf("size = %d > budget %d", r.size, r.budget)
	}
}

// TestRing_ChunkSplitting verifies writes larger than 32 KiB are split into
// 32 KiB chunks so eviction granularity stays fine.
func TestRing_ChunkSplitting(t *testing.T) {
	r := newRing(1 << 20)
	big := bytes.Repeat([]byte{'x'}, 32<<10+5555) // ~37.6 KiB
	r.append(big, true, 1234)
	got := r.replay()
	if len(got) != 2 {
		t.Fatalf("split: %d chunks, want 2", len(got))
	}
	if len(got[0].data) != maxChunkBytes {
		t.Errorf("chunk[0] len = %d, want %d", len(got[0].data), maxChunkBytes)
	}
	if len(got[1].data) != 5555 {
		t.Errorf("chunk[1] len = %d, want %d", len(got[1].data), 5555)
	}
	if !got[1].stderr {
		t.Error("stderr flag lost on tail")
	}
	if got[0].tsNs != 1234 || got[1].tsNs != 1234 {
		t.Error("tsNs not stamped")
	}
	if got[0].seq+1 != got[1].seq {
		t.Errorf("split chunks not consecutive: %d,%d", got[0].seq, got[1].seq)
	}
}

// TestRing_ReplayFollowAtomicity verifies that a follower started concurrently
// with many appends sees every chunk exactly once (replay + follow combined),
// with neither gaps nor duplicates. Uses sequence-numbered chunks.
func TestRing_ReplayFollowAtomicity(t *testing.T) {
	const N = 1000
	r := newRing(1 << 20)

	// Seed an initial batch so the snapshot portion is non-empty.
	seed := make([]byte, 13)
	for i := 0; i < 50; i++ {
		copy(seed, fmt.Sprintf("seed-%05d", i))
		r.append(seed, false, int64(i))
	}

	// Subscribe: atomically snapshot current chunks AND register a follower
	// for everything appended afterwards.
	snapshot, out := r.replayAndFollow(make(chan struct{})) // never-closed done

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < N; i++ {
			b := fmt.Appendf(nil, "concur-%05d", i)
			r.append(b, i%4 == 0, int64(i))
		}
	}()

	// Wait for all appends to enter the queue / chunk list BEFORE finishing
	// the ring, so the drain goroutine is guaranteed to deliver every chunk
	// before it observes finished+empty and closes the channel.
	wg.Wait()
	r.finish()

	// Collect everything: snapshot first (already in hand), then the follow
	// channel until the ring finishes.
	seen := make(map[int64]struct{})
	for _, c := range snapshot {
		seen[c.seq] = struct{}{}
	}
	for c := range out {
		if _, dup := seen[c.seq]; dup {
			t.Fatalf("duplicate seq %d in follow stream", c.seq)
		}
		seen[c.seq] = struct{}{}
	}

	// Every sequence number in 1..(50 + N) must appear.
	if got := len(seen); got != 50+N {
		t.Fatalf("seen %d seqs, want %d; gap in replay+follow", got, 50+N)
	}
	for s := int64(1); s <= int64(50+N); s++ {
		if _, ok := seen[s]; !ok {
			t.Fatalf("missing seq %d (gap)", s)
		}
	}
}

// TestRing_FollowClosesOnFinish verifies that finish() closes follow channels
// once queued chunks have been drained.
func TestRing_FollowClosesOnFinish(t *testing.T) {
	r := newRing(1 << 20)
	r.append([]byte("hello"), false, 1)
	snapshot, out := r.replayAndFollow(nil)
	r.append([]byte("world"), false, 2)
	r.finish()

	// Combined view: snapshot (hello) + follow (world).
	var chunks []ringChunk
	chunks = append(chunks, snapshot...)
	for c := range out {
		chunks = append(chunks, c)
	}
	if len(chunks) != 2 || string(chunks[0].data) != "hello" || string(chunks[1].data) != "world" {
		t.Fatalf("followed chunks = %v", chunksToString(chunks))
	}
}

// TestRing_FollowCancel verifies that closing the done channel (as a Logs
// client disconnect would) causes the follow goroutine to drop remaining
// queued chunks and the channel to close, without blocking on append.
func TestRing_FollowCancel(t *testing.T) {
	r := newRing(1 << 20)
	done := make(chan struct{})
	_, out := r.replayAndFollow(done)
	// Append a chunk, then immediately cancel; the consumer may or may not
	// observe it, but the channel MUST close.
	r.append([]byte("a"), false, 0)
	close(done)
	// Append after cancel must not block the publisher.
	appended := make(chan struct{})
	go func() {
		// Keep appending a little to prove the publisher is unblocked.
		for i := 0; i < 100; i++ {
			r.append([]byte("b"), false, 0)
		}
		close(appended)
	}()
	select {
	case <-appended:
	case <-time.After(2 * time.Second):
		t.Fatal("publisher blocked after follow cancel")
	}
	// Drain remainder so the cancel bridge goroutine can exit cleanly.
	for range out {
	}
}

// TestRing_ConcurrentAppenders exercises append under load and checks the
// sequence numbers remain strictly increasing in a single follower.
func TestRing_ConcurrentAppenders(t *testing.T) {
	r := newRing(1 << 20)
	_, out := r.replayAndFollow(nil)
	var wg sync.WaitGroup
	producers := 8
	per := 500
	wg.Add(producers)
	for p := 0; p < producers; p++ {
		p := p
		go func() {
			defer wg.Done()
			prng := rand.New(rand.NewSource(int64(p)))
			for i := 0; i < per; i++ {
				b := make([]byte, prng.Intn(200)+1)
				prng.Read(b)
				r.append(b, p%2 == 1, int64(i))
			}
		}()
	}
	wg.Wait()  // all appends queued first
	r.finish() // drain should now deliver everything + close out

	var maxSeq int64
	var broken atomic.Bool
	for c := range out {
		if c.seq <= maxSeq {
			broken.Store(true)
		}
		if c.seq > maxSeq {
			maxSeq = c.seq
		}
	}
	if broken.Load() {
		t.Fatal("seq order broken in single-follower stream")
	}
}

// chunksToString flattens chunks for an error message.
func chunksToString(cs []ringChunk) string {
	var b []byte
	for i, c := range cs {
		if i > 0 {
			b = append(b, ' ')
		}
		b = append(b, c.data...)
	}
	return string(b)
}
