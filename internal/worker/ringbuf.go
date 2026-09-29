package worker

import (
	"sync"
	"sync/atomic"
)

// ringChunk is one stored log entry. seq is a strictly-increasing sequence
// number assigned at append time, used by tests to verify replay+follow
// produce a gap-free, duplicate-free stream under concurrent appends.
type ringChunk struct {
	data   []byte
	stderr bool
	tsNs   int64
	seq    int64
}

// maxChunkBytes caps each stored chunk so eviction granularity stays fine
// (a single huge write does not consume the whole budget as one chunk).
const maxChunkBytes = 32 << 10 // 32 KiB

// defaultRingBytes is the per-context ring budget applied when a Config leaves
// RingBytes at zero (plan §8: 1 MiB/context).
const defaultRingBytes = 1 << 20

// ring is a byte-budget ring buffer of tagged log chunks that supports
// atomic replay+follow: a single locked section snapshots the current chunk
// list and registers a new follow subscription, guaranteeing the subscriber
// neither misses chunks appended immediately after the snapshot nor sees them
// twice in the replay portion.
//
// Follow delivery is gap-free and duplicate-free within the ring's lifetime:
// each subscriber owns an unbounded in-memory queue (drained by a per-
// subscriber goroutine into a bounded output channel) so a slow consumer's
// only cost is queue memory, never lost chunks. The queue is pumped until
// the ring is finished AND the queue is fully drained, at which point the
// subscriber's output channel is closed.
type ring struct {
	mu       sync.Mutex
	cond     *sync.Cond
	budget   int
	chunks   []ringChunk
	size     int
	seq      int64
	finished bool
	subs     map[*ringSub]struct{}
}

// ringSub is a single follow subscription backed by an unbounded queue.
type ringSub struct {
	r          *ring
	q          []ringChunk // owned under ring.mu
	out        chan ringChunk
	done       chan struct{} // closed by cancel to stop the drain goroutine
	closed     atomic.Bool   // set when s.out is closed (under ring.mu)
	closedflag bool          // mirrors for the drain's exit check (under ring.mu)
}

func newRing(budget int) *ring {
	if budget <= 0 {
		budget = defaultRingBytes
	}
	r := &ring{budget: budget, subs: map[*ringSub]struct{}{}}
	r.cond = sync.NewCond(&r.mu)
	return r
}

// append stores data as one or more chunks (each ≤ maxChunkBytes), tagged
// stderr, timestamped tsNs. It appends to every live follow subscription's
// queue and wakes their drain goroutines. Eviction (oldest-whole-chunk
// first) keeps total stored bytes ≤ budget; at least one chunk (the most
// recently appended) is always retained so the buffer is never empty after an
// append unless it spans the entire budget on its own.
func (r *ring) append(data []byte, stderr bool, tsNs int64) {
	if len(data) == 0 {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	for len(data) > 0 {
		n := len(data)
		if n > maxChunkBytes {
			n = maxChunkBytes
		}
		r.seq++
		c := ringChunk{
			data:   append([]byte(nil), data[:n]...),
			stderr: stderr,
			tsNs:   tsNs,
			seq:    r.seq,
		}
		r.chunks = append(r.chunks, c)
		r.size += len(c.data)
		for s := range r.subs {
			s.q = append(s.q, c)
		}
		data = data[n:]
	}
	r.evictLocked()
	r.cond.Broadcast()
}

// evictLocked drops oldest whole chunks until size ≤ budget or a single
// chunk remains (never evict everything). Subscriber queues are not affected:
// they already received their copy of an evicted chunk at append time.
func (r *ring) evictLocked() {
	for r.size > r.budget && len(r.chunks) > 1 {
		c := r.chunks[0]
		r.chunks[0] = ringChunk{}
		r.chunks = append([]ringChunk(nil), r.chunks[1:]...)
		r.size -= len(c.data)
	}
}

// snapshotLocked returns a defensive copy of the current chunk list.
func (r *ring) snapshotLocked() []ringChunk {
	out := make([]ringChunk, len(r.chunks))
	copy(out, r.chunks)
	return out
}

// replay returns a snapshot of the current chunks in order. Used by the Logs
// RPC for the replay-only path.
func (r *ring) replay() []ringChunk {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snapshotLocked()
}

// followChannelBufferSize is the per-subscriber output channel capacity. The
// drain goroutine pulls chunks from the unbounded queue into this channel;
// a slow consumer only stalls the drain goroutine (and grows the queue), not
// the publisher.
const followChannelBufferSize = 256

// replayAndFollow atomically snapshots the current chunk list AND registers
// a follow subscription whose drain goroutine delivers every chunk appended
// after the snapshot (in order, gap-free, duplicate-free) on the returned
// channel. The drain goroutine exits when either:
//   - the caller signals done (e.g. the gRPC client cancelled the Logs RPC),
//     in which case remaining queued chunks are dropped and the channel is
//     closed;
//   - or the ring is finished AND the subscriber's queue is fully drained,
//     in which case the channel is closed.
//
// On return the subscription is removed from the ring.
func (r *ring) replayAndFollow(done <-chan struct{}) (snapshot []ringChunk, out <-chan ringChunk) {
	r.mu.Lock()
	snapshot = r.snapshotLocked()
	s := &ringSub{
		r:    r,
		out:  make(chan ringChunk, followChannelBufferSize),
		done: make(chan struct{}),
	}
	r.subs[s] = struct{}{}
	r.mu.Unlock()

	// Bridge the caller's done channel to the subscription's internal done
	// channel so a Logs client disconnect tears the subscription down
	// regardless of where the drain goroutine is parked.
	if done != nil {
		go func() {
			select {
			case <-done:
				s.cancel()
			case <-s.done:
			}
		}()
	}
	r.startDrain(s, done)
	return snapshot, s.out
}

// startDrain launches the per-subscriber queue→channel pump goroutine.
func (r *ring) startDrain(s *ringSub, done <-chan struct{}) {
	go func() {
		defer func() {
			r.mu.Lock()
			delete(r.subs, s)
			if !s.closedflag {
				close(s.out)
				s.closedflag = true
				s.closed.Store(true)
			}
			r.mu.Unlock()
			if done != nil {
				// already exited; nothing more to select against.
			}
		}()
		for {
			r.mu.Lock()
			for len(s.q) == 0 && !r.finished && !isClosed(s.done) {
				r.cond.Wait()
			}
			if isClosed(s.done) {
				// Cancelled: drop remaining and exit.
				s.q = nil
				r.mu.Unlock()
				return
			}
			if len(s.q) == 0 {
				// r.finished is true and the queue is empty.
				r.mu.Unlock()
				return
			}
			batch := s.q
			s.q = nil
			r.mu.Unlock()

			for _, c := range batch {
				select {
				case s.out <- c:
				case <-s.done:
					return
				}
			}
		}
	}()
}

// cancel closes the subscriber's done channel and wakes its drain goroutine;
// the goroutine observes the closed channel on its next send or at its wait
// loop wakeup and exits, dropping any remaining queued chunks.
func (s *ringSub) cancel() {
	closeOnce(s.done)
	// Wake the drain goroutine in case it is parked in cond.Wait.
	s.r.mu.Lock()
	s.r.cond.Broadcast()
	s.r.mu.Unlock()
}

// closeOnce closes ch exactly once.
func closeOnce(ch chan<- struct{}) {
	defer func() { _ = recover() }()
	close(ch)
}

// isClosed reports whether ch has been closed, using a non-blocking receive.
func isClosed(ch chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

// finish marks the ring as finished, waking all drain goroutines so they can
// drain remaining queued chunks and then close their output channels.
func (r *ring) finish() {
	r.mu.Lock()
	r.finished = true
	r.cond.Broadcast()
	r.mu.Unlock()
}
