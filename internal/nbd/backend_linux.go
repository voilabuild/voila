//go:build linux

package nbd

import (
	"context"
	"sync"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
)

const blockSize = 4096

// prefetchConcurrency bounds the parallel chunk fetch in a background
// file-aware prefetch. 8 keeps a single HTTP/2 connection's streams busy
// without overwhelming a WAN link or the local store's writer; it matches the
// FUSE FileReader's prefetch fan-out so both backends behave alike.
const prefetchConcurrency = 8

// chunkBackend implements go-nbd's Backend interface, serving the virtual
// EROFS device: metadata from RAM, data from the chunk store.
type chunkBackend struct {
	metadata   []byte // pinned EROFS image (metadata region)
	dataOffset int64  // byte offset where data region starts
	slotTable  []chunkstore.ChunkID
	store      chunkstore.ChunkStore
	deviceSize int64

	// chunkLRU is a small in-memory cache of recently-fetched chunks,
	// mitigating the 4 KiB read-amplification (one NBD request per block,
	// but each chunk is 1 MiB). The kernel page cache handles repeated
	// reads of the same block; this cache avoids re-fetching the same 1 MiB
	// chunk for different 4 KiB blocks within it.
	chunkLRU *chunkCache

	// fileSlots maps a file inode to its ordered slot indices (built by
	// erofsadapter.Build). slotToFile is the reverse: each slot → one file
	// that references it (the first, by build order). Together they drive
	// file-aware prefetch: when a data-region read touches a slot, the
	// backend kicks off a best-effort background fetch of the *rest* of
	// that file's chunks in parallel — the "which ones do we need" read-
	// ahead from the roadmap. This turns a cold-start file from N serial
	// WAN RTTs (one per chunk as the read pattern touches it) into ~1 RTT
	// for the inline chunk + a parallel batch for the rest, so a scattered
	// mmap of a shared library no longer pays per-chunk latency. Without
	// this the EROFS path fetched one chunk at a time, blocking the kernel
	// on each — the dominant cost of a network cold start.
	fileSlots  map[uint64][]uint64
	slotToFile map[uint64]uint64

	// pfSeen singleflights prefetch per file inode: each file is prefetched
	// at most once for the lifetime of the device. A sync.Map keeps the
	// hot read path lock-free (the check is a single Load).
	pfSeen sync.Map
}

func newChunkBackend(result *erofsadapter.BuildResult, store chunkstore.ChunkStore) *chunkBackend {
	b := &chunkBackend{
		metadata:   result.Metadata,
		dataOffset: result.DataOffset,
		slotTable:  result.SlotTable,
		store:      store,
		deviceSize: result.DeviceSize,
		chunkLRU:   newChunkCache(16), // 16 MiB cache
		fileSlots:  result.FileSlots,
		slotToFile: make(map[uint64]uint64, len(result.SlotTable)),
	}
	// Build the reverse slot → file map. A slot can be referenced by
	// several files (dedup); we keep the first file in build order, which
	// is enough to trigger prefetch of that file's remaining chunks — the
	// common case is a chunk unique to one file.
	for ino, slots := range result.FileSlots {
		for _, s := range slots {
			if _, ok := b.slotToFile[s]; !ok {
				b.slotToFile[s] = ino
			}
		}
	}
	return b
}

// ReadAt serves a read request from the kernel.
//
// For offsets in the metadata region (< dataOffset): serve from the pinned
// metadata bytes — instant, no network.
//
// For offsets in the data region (>= dataOffset): translate to a slot
// index, fetch the chunk from the store (via the LRU cache), and copy the
// requested slice.
//
// A single NBD request can span the metadata/data boundary or multiple 1 MiB
// slots (the kernel does this for contiguous EROFS chunks larger than 1 MiB).
// We walk the request and always return a full buffer (zero-fill) so the
// NBD protocol does not desync.
func (b *chunkBackend) ReadAt(p []byte, off int64) (int, error) {
	if off < 0 {
		clear(p)
		return len(p), nil
	}
	done := 0
	for done < len(p) {
		n := b.readAtOnce(p[done:], off+int64(done))
		if n <= 0 {
			clear(p[done:])
			break
		}
		done += n
	}
	return len(p), nil
}

// readAtOnce copies one contiguous region starting at off: either a suffix
// of the metadata blob or a suffix of a single 1 MiB slot. Returns 0 if
// off is past the device or the slot has no data (caller zero-fills).
func (b *chunkBackend) readAtOnce(p []byte, off int64) int {
	if off >= b.deviceSize {
		return 0
	}

	if off < b.dataOffset {
		end := off + int64(len(p))
		if end > b.dataOffset {
			end = b.dataOffset
		}
		return copy(p, b.metadata[off:end])
	}

	dataOff := off - b.dataOffset
	slot := dataOff / erofsadapter.ChunkSize
	chunkOff := dataOff % erofsadapter.ChunkSize
	if int(slot) >= len(b.slotTable) {
		return 0
	}

	cid := b.slotTable[slot]
	if cid == (chunkstore.ChunkID{}) {
		return 0
	}

	// Kick off file-aware prefetch for the file that owns this slot. It
	// fetches the file's *other* chunks in parallel over the shared HTTP/2
	// connection (singleflighted per file, Stat-gated per chunk) so the
	// next reads of the same file hit the local cache instead of paying a
	// WAN RTT each. Best-effort: the inline fetch below proceeds regardless.
	b.maybePrefetch(uint64(slot))

	chunk, err := b.chunkLRU.get(context.Background(), cid, b.store)
	if err != nil {
		return 0
	}
	if chunkOff >= int64(len(chunk)) {
		return 0
	}

	avail := int64(len(chunk)) - chunkOff
	slotLeft := erofsadapter.ChunkSize - chunkOff
	if avail > slotLeft {
		avail = slotLeft
	}
	if avail > int64(len(p)) {
		avail = int64(len(p))
	}
	return copy(p, chunk[chunkOff:chunkOff+avail])
}

// maybePrefetch triggers a one-shot, best-effort background prefetch of the
// file that owns slot, fetching the file's *other* chunks in parallel over the
// shared HTTP/2 connection. It is singleflighted per file inode (pfSeen): the
// first read of any chunk of a file launches the prefetch once; subsequent
// reads of the same file are a no-op here. The inline read owns slot's chunk,
// so the prefetch skips it (no redundant WAN fetch — the two would race the
// same id, and store.Get is idempotent anyway, but skipping saves a request).
//
// The prefetch uses context.Background so it outlives the triggering read's
// per-syscall context; errors are ignored (a failed prefetch means a later
// read fetches that chunk inline as before). Each chunk is Stat-gated: if the
// local cache already holds it (warm re-read, or a chunk shared with another
// file already prefetched), the Get is skipped entirely.
func (b *chunkBackend) maybePrefetch(slot uint64) {
	ino, ok := b.slotToFile[slot]
	if !ok {
		return // slot not in any file (shouldn't happen for data slots)
	}
	if _, done := b.pfSeen.LoadOrStore(ino, struct{}{}); done {
		return // this file already prefetched
	}
	slots, ok := b.fileSlots[ino]
	if !ok || len(slots) <= 1 {
		return // single-chunk file: nothing to prefetch
	}
	go b.prefetchFile(ino, slot, slots)
}

// prefetchFile fetches every chunk of the file ino (except the skipSlot the
// inline read owns) into the local cache, in parallel and bounded by
// prefetchConcurrency. It dedups chunk ids (a file may reference the same
// chunk twice) and Stat-gates each so already-cached chunks are skipped.
func (b *chunkBackend) prefetchFile(ino, skipSlot uint64, slots []uint64) {
	ids := make([]chunkstore.ChunkID, 0, len(slots))
	seen := make(map[chunkstore.ChunkID]struct{}, len(slots))
	for _, s := range slots {
		if s == skipSlot {
			continue
		}
		if int(s) >= len(b.slotTable) {
			continue
		}
		cid := b.slotTable[s]
		if cid == (chunkstore.ChunkID{}) {
			continue // hole slot
		}
		if _, dup := seen[cid]; dup {
			continue
		}
		seen[cid] = struct{}{}
		ids = append(ids, cid)
	}
	if len(ids) == 0 {
		return
	}
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
			if _, ok := b.store.Stat(id); ok {
				return // already in the local cache
			}
			_, _ = b.store.Get(bg, id) // write-through to the local cache
		}(id)
	}
	wg.Wait()
}

func (b *chunkBackend) WriteAt(p []byte, off int64) (int, error) {
	return 0, nil // read-only
}

func (b *chunkBackend) Size() (int64, error) {
	return b.deviceSize, nil
}

func (b *chunkBackend) Sync() error {
	return nil // read-only
}

// ----- chunk LRU cache -----

// chunkCache is a simple LRU cache of recently-fetched chunks. It avoids
// re-fetching (and re-decompressing) the same 1 MiB chunk when the kernel
// issues multiple 4 KiB reads within the same chunk.
type chunkCache struct {
	mu    sync.Mutex
	cap   int
	items map[chunkstore.ChunkID][]byte
	order []chunkstore.ChunkID // LRU order: front = oldest
}

func newChunkCache(cap int) *chunkCache {
	return &chunkCache{
		cap:   cap,
		items: make(map[chunkstore.ChunkID][]byte),
		order: make([]chunkstore.ChunkID, 0, cap),
	}
}

func (c *chunkCache) get(ctx context.Context, id chunkstore.ChunkID, store chunkstore.ChunkStore) ([]byte, error) {
	c.mu.Lock()
	if data, ok := c.items[id]; ok {
		c.mu.Unlock()
		return data, nil
	}
	c.mu.Unlock()

	data, err := store.Get(ctx, id)
	if err != nil {
		return nil, err
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.items) >= c.cap {
		// Evict oldest.
		oldest := c.order[0]
		delete(c.items, oldest)
		c.order = c.order[1:]
	}
	c.items[id] = data
	c.order = append(c.order, id)
	return data, nil
}
