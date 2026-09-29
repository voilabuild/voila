package mount

import (
	"context"
	"errors"
	"io"
	"sync"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"
)

// getChunk fetches the raw bytes of one chunk; implemented by ChunkStore.Get
// or by FileReader's caching wrapper.
type getChunk func(ctx context.Context, id chunkstore.ChunkID) ([]byte, error)

// ReadAt fills dst from the logical content of f starting at offset off. It
// assembles the result from f's ordered Block list, fetching each referenced
// chunk from store on demand. Holes — blocks with an empty chunk_id, or gaps
// between blocks — serve zeros. Reads past f.Size return io.EOF semantics
// (a short read).
//
// ReadAt does not cache chunk bytes: the kernel page cache sits above us and
// the store is the seam below (plan §6). It is safe for concurrent use; the
// underlying ChunkStore is responsible for any concurrency it requires.
func ReadAt(ctx context.Context, store chunkstore.ChunkStore, f *voilapb.File, dst []byte, off int64) (int, error) {
	return readAt(ctx, store.Get, f, dst, off)
}

func readAt(ctx context.Context, get getChunk, f *voilapb.File, dst []byte, off int64) (int, error) {
	if f == nil {
		return 0, errors.New("mount: ReadAt on nil file")
	}
	if off < 0 {
		return 0, errors.New("mount: negative read offset")
	}
	size := int64(f.Size)
	if off >= size {
		return 0, io.EOF
	}
	end := off + int64(len(dst))
	if end > size {
		end = size
	}
	// Goal bytes to place into dst before EOF.
	goal := end - off

	// fillZeros writes n zero bytes into dst[pos:]; it advances pos and
	// stops once we have produced `goal` bytes total.
	n := 0
	fillZeros := func(count int) {
		if count <= 0 {
			return
		}
		if n+count > int(goal) {
			count = int(goal) - n
		}
		for i := 0; i < count; i++ {
			dst[n] = 0
			n++
		}
	}
	// writeBlockBytes copies src[chunkOff:chunkOff+segLen] into dst at the
	// current fill position.
	writeBytes := func(src []byte, chunkOff, segLen int) error {
		if segLen <= 0 {
			return nil
		}
		if n+segLen > int(goal) {
			segLen = int(goal) - n
		}
		copy(dst[n:n+segLen], src[chunkOff:chunkOff+segLen])
		n += segLen
		return nil
	}

	for _, b := range f.Blocks {
		if ctx.Err() != nil {
			return n, ctx.Err()
		}
		blkStart := int64(b.OffsetInFile)
		blkLen := int64(b.LogicalLen)
		blkEnd := blkStart + blkLen

		if blkEnd <= off {
			// Block lies entirely before the read window; skip.
			continue
		}
		if blkStart >= end {
			// Blocks are ordered by offset; nothing later can intersect.
			break
		}

		// Zero-fill any gap between the current fill position (off+n) and
		// this block's start (covers holes and inter-block gaps).
		if blkStart > off+int64(n) {
			fillZeros(int(blkStart - (off + int64(n))))
		}

		segStart := blkStart
		if off > segStart {
			segStart = off
		}
		segEnd := blkEnd
		if end < segEnd {
			segEnd = end
		}
		segLen := int(segEnd - segStart)
		if segLen <= 0 {
			continue
		}
		chunkOff := int(segStart - blkStart)

		if len(b.ChunkId) == 0 {
			// Explicit hole block: serve zeros.
			fillZeros(segLen)
			continue
		}
		var cid chunkstore.ChunkID
		if len(b.ChunkId) != len(cid) {
			return n, errors.New("mount: block chunk_id has wrong length")
		}
		copy(cid[:], b.ChunkId)
		chunk, err := get(ctx, cid)
		if err != nil {
			return n, err
		}
		if uint64(len(chunk)) < b.LogicalLen {
			return n, errors.New("mount: chunk shorter than block logical_len")
		}
		if err := writeBytes(chunk, chunkOff, segLen); err != nil {
			return n, err
		}
	}

	// Zero-fill the tail of the read window (e.g. a hole trailing past the
	// last block, or a file with no blocks at all but a positive size).
	if int64(n) < goal {
		fillZeros(int(goal - int64(n)))
	}

	var err error
	if off+int64(n) >= size {
		err = io.EOF
	}
	return n, err
}

// FileReader reads one file's content with a single-chunk cache. The kernel
// issues FUSE reads in windows smaller than our 1 MiB chunks (128 KiB
// typically), so without a cache every kernel read re-fetches, re-verifies and
// re-decompresses a full chunk — an ~8x amplification on sequential reads.
// One cached chunk per open handle removes it; the kernel page cache handles
// everything above us.
//
// On the first read of a multi-chunk file, FileReader also kicks off a
// best-effort background prefetch that fetches the file's remaining chunks in
// parallel (bounded concurrency). This turns the cold-start cost of a file
// from N sequential WAN RTTs (one per chunk as the read pattern touches it)
// into ~1 RTT for the inline chunk + a parallel batch for the rest, so a
// scattered mmap of a shared library no longer pays per-chunk latency. It is
// the read-prefetch step from the plan's roadmap ("sized to RTT × BDP"); the
// current implementation is full-file (no windowing yet), which is ideal for
// the small, fully-read files of a cold start and a known tradeoff for a
// huge-file partial read.
//
// FileReader is safe for concurrent use.
type FileReader struct {
	store chunkstore.ChunkStore
	f     *voilapb.File

	mu       sync.Mutex
	cachedID chunkstore.ChunkID
	cached   []byte // nil when nothing cached

	pfOnce     sync.Once
	pfMu       sync.Mutex
	pfInflight map[chunkstore.ChunkID]chan struct{} // prefetched chunks in flight; nil until prefetch registers them
}

// prefetchConcurrency bounds the parallel chunk fetch in a background
// prefetch. 8 keeps a single HTTP/2 connection's streams busy without
// overwhelming a WAN link or the local store's writer.
const prefetchConcurrency = 8

// NewFileReader returns a FileReader over f backed by store.
func NewFileReader(store chunkstore.ChunkStore, f *voilapb.File) *FileReader {
	return &FileReader{store: store, f: f}
}

// ReadAt behaves like the package-level ReadAt but serves repeated reads of
// the same chunk from the handle's cache. The first call also triggers a
// one-shot background prefetch of the file's other chunks (see FileReader).
func (r *FileReader) ReadAt(ctx context.Context, dst []byte, off int64) (int, error) {
	r.pfOnce.Do(func() { go r.prefetch(off) })
	return readAt(ctx, r.getCached, r.f, dst, off)
}

// prefetch fetches every chunk the file references, in parallel and
// best-effort, into the local cache. It skips the chunk that the triggering
// read is itself fetching inline (off's first intersecting block) so the
// inline read and the prefetch do not race the same chunk over the WAN. Errors
// are ignored: a failed prefetch simply means a later read fetches that chunk
// inline as before. The prefetch uses context.Background so it outlives the
// triggering read's per-syscall context.
func (r *FileReader) prefetch(off int64) {
	// Collect unique, non-hole chunk ids in file-offset order, skipping the
	// block the inline read is fetching (the first block intersecting off).
	skipID, hasSkip := firstBlockChunkID(r.f, off)
	ids := make([]chunkstore.ChunkID, 0, len(r.f.Blocks))
	seen := make(map[chunkstore.ChunkID]struct{}, len(r.f.Blocks))
	for _, b := range r.f.Blocks {
		if len(b.ChunkId) == 0 {
			continue // hole
		}
		var cid chunkstore.ChunkID
		copy(cid[:], b.ChunkId)
		if _, dup := seen[cid]; dup {
			continue
		}
		seen[cid] = struct{}{}
		if hasSkip && cid == skipID {
			continue // inline read owns this one
		}
		ids = append(ids, cid)
	}
	if len(ids) == 0 {
		return
	}
	// Register an in-flight signal channel for every prefetched chunk BEFORE
	// launching any fetch goroutine. getCached inspects this map to wait on a
	// prefetch already in flight instead of racing it with a second remote GET
	// for the same chunk (singleflight). The channel is closed when that
	// chunk's fetch completes (success, already-cached, or failure).
	chans := make(map[chunkstore.ChunkID]chan struct{}, len(ids))
	for _, id := range ids {
		chans[id] = make(chan struct{})
	}
	r.pfMu.Lock()
	r.pfInflight = chans
	r.pfMu.Unlock()

	// Bounded parallel fetch into the local cache. Stat-gate each chunk: if
	// the local cache already holds it (warm re-read, or a chunk shared with
	// another file), skip the Get entirely — store.Get on a hit is cheap but
	// not free, and this keeps the prefetch from re-reading already-cached
	// chunks on a re-opened handle. On a miss, store.Get fetches from the
	// remote and writes through.
	sem := make(chan struct{}, prefetchConcurrency)
	var wg sync.WaitGroup
	// Tag the context so a TraceStore (when tracing is enabled) classifies
	// these Gets as prefetch traffic, not workload (demand) latency.
	bg := chunkstore.WithSource(context.Background(), chunkstore.SourcePrefetch)
	for _, id := range ids {
		wg.Add(1)
		sem <- struct{}{}
		go func(id chunkstore.ChunkID) {
			defer wg.Done()
			defer func() { <-sem }()
			defer close(chans[id])
			if _, ok := r.store.Stat(id); ok {
				return // already in the local cache
			}
			_, _ = r.store.Get(bg, id)
		}(id)
	}
	wg.Wait()
}

// firstBlockChunkID returns the chunk id of the first block in f that
// intersects offset off, and whether one exists (a hole block returns false so
// the caller does not skip a real chunk). Mirrors readAt's intersection logic.
func firstBlockChunkID(f *voilapb.File, off int64) (chunkstore.ChunkID, bool) {
	if f == nil || off < 0 {
		return chunkstore.ChunkID{}, false
	}
	for _, b := range f.Blocks {
		blkStart := int64(b.OffsetInFile)
		blkEnd := blkStart + int64(b.LogicalLen)
		if blkEnd <= off {
			continue
		}
		if blkStart > off {
			break // blocks are ordered; nothing earlier intersects
		}
		if len(b.ChunkId) == 0 {
			return chunkstore.ChunkID{}, false // hole serves zeros, no fetch
		}
		var cid chunkstore.ChunkID
		copy(cid[:], b.ChunkId)
		return cid, true
	}
	return chunkstore.ChunkID{}, false
}

func (r *FileReader) getCached(ctx context.Context, id chunkstore.ChunkID) ([]byte, error) {
	r.mu.Lock()
	if r.cached != nil && r.cachedID == id {
		b := r.cached
		r.mu.Unlock()
		return b, nil
	}
	r.mu.Unlock()

	// Singleflight against the background prefetch: if a chunk is already
	// being fetched by prefetch, wait for it rather than issuing a second
	// remote GET for the same id. After the signal closes, store.Get hits
	// the local cache (prefetch wrote it through) — or, if the prefetch
	// failed, falls back to a normal fetch.
	r.pfMu.Lock()
	ch, inflight := r.pfInflight[id]
	r.pfMu.Unlock()
	if inflight {
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}

	b, err := r.store.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	r.cachedID = id
	r.cached = b
	r.mu.Unlock()
	return b, nil
}
