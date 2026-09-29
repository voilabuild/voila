// Package mount implements the read-only FUSE daemon that exposes a merged
// Drift manifest tree (see plan §6). The FUSE glue lives in build-tagged files
// (daemon.go / ops.go / mount_linux_test.go, all `//go:build linux`); the lazy
// manifest tree and sparse-aware file reader are OS-independent so they (and
// their unit tests) build and run on darwin too.
package mount

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// manifestFetchTimeout bounds a lazy subtree-manifest fetch. The fetch is
// decoupled from the FUSE request context (see fetchAndIndex) so it is not
// aborted by FUSE_INTERRUPT, but it must not hang forever either: the
// registry client's transport bounds only the response-header wait
// (ResponseHeaderTimeout=60s), not a mid-body stall. A manifest chunk is
// small (subtrees split at ~64 KiB), so 2 minutes is generous headroom over
// the header timeout and never aborts a healthy fetch — it only reclaims a
// goroutine stuck on a dead/stalled connection. On timeout the manifest
// stays uncached and the next lookup retries, identical to a network error.
const manifestFetchTimeout = 2 * time.Minute

// ErrNotFound is returned when an inode or path component cannot be resolved
// in any loaded manifest or any loadable external subtree.
var ErrNotFound = errors.New("mount: inode not found")

// NodeKind discriminates the kinds of manifest entries a node can represent.
type NodeKind int

const (
	// KindUnknown is the zero value; it is never returned by a successfully
	// resolved *NodeInfo.
	KindUnknown NodeKind = iota
	// KindDir / KindFile / KindSymlink / KindDevice mirror the manifest
	// message kinds.
	KindDir
	KindFile
	KindSymlink
	KindDevice
)

// NodeInfo is resolved metadata for one manifest inode. Exactly one of
// File / Dir / Symlink / Device is non-nil, matching the NodeKind.
type NodeInfo struct {
	Inode   uint64
	Kind    NodeKind
	File    *voilapb.File
	Dir     *voilapb.Dir
	Symlink *voilapb.Symlink
	Device  *voilapb.Device
}

// DirEntry is one entry returned by ReadDir.
type DirEntry struct {
	Name  string
	Inode uint64
	Kind  NodeKind
}

// Tree is a lazily-loaded view over a chunk-addressed manifest tree. It is
// safe for concurrent use. External (split) subtrees are fetched from the
// chunk store on first touch and never at Load time (plan §4.2 lazy-start).
type Tree struct {
	store chunkstore.ChunkStore

	mu sync.Mutex

	// manifests maps every loaded manifest's chunk id to the unmarshaled
	// *Manifest. The root is inserted by Load; children are inserted lazily.
	manifests map[chunkstore.ChunkID]*voilapb.Manifest

	// Per-inode indices into the manifest that owns each inode. dirByInode
	// in particular lets Get answer "what kind is this inode" in O(1).
	dirByInode     map[uint64]*voilapb.Dir
	fileByInode    map[uint64]*voilapb.File
	symlinkByInode map[uint64]*voilapb.Symlink
	deviceByInode  map[uint64]*voilapb.Device

	// externalSubtrees maps a dir inode (key of some loaded manifest's
	// external_subtrees) to the chunk id of the not-yet-loaded child
	// Manifest that owns that dir.
	externalSubtrees map[uint64]chunkstore.ChunkID

	// inflight guards singleflight semantics for concurrent loads of the
	// same chunk id. The closed channel broadcasts the result.
	inflight map[chunkstore.ChunkID]*inflightEntry

	root uint64
}

// inflightEntry records the outcome of a single in-flight (or completed)
// manifest fetch so concurrent waiters receive the same result.
type inflightEntry struct {
	done chan struct{}
	m    *voilapb.Manifest
	err  error
}

// Load fetches and unmarshals the root Manifest chunk identified by root,
// indexes it, and returns a *Tree rooted at inode 1 (the manifest's first dir
// — see ingest.AssignInodes). It does NOT load any external subtrees; those
// are fetched on demand by Get/Lookup/ReadDir.
func Load(ctx context.Context, store chunkstore.ChunkStore, root chunkstore.ChunkID) (*Tree, error) {
	if store == nil {
		return nil, errors.New("mount: nil chunk store")
	}
	t := &Tree{
		store:            store,
		manifests:        make(map[chunkstore.ChunkID]*voilapb.Manifest),
		dirByInode:       make(map[uint64]*voilapb.Dir),
		fileByInode:      make(map[uint64]*voilapb.File),
		symlinkByInode:   make(map[uint64]*voilapb.Symlink),
		deviceByInode:    make(map[uint64]*voilapb.Device),
		externalSubtrees: make(map[uint64]chunkstore.ChunkID),
		inflight:         make(map[chunkstore.ChunkID]*inflightEntry),
	}
	if _, err := t.loadManifest(ctx, root); err != nil {
		return nil, fmt.Errorf("mount: load root manifest %s: %w", root, err)
	}
	// The root dir inode is defined to be 1 by the ingester's sorted-path inode
	// assignment (the empty path sorts first). Sanity-check rather than assume.
	if d, ok := t.dirByInode[1]; ok {
		_ = d
		t.root = 1
	} else {
		// Fall back: pick the lowest inode in the root manifest's dirs list.
		var lowest uint64
		var have bool
		for ino := range t.dirByInode {
			if !have || ino < lowest {
				lowest = ino
				have = true
			}
		}
		if !have {
			return nil, errors.New("mount: root manifest has no dirs")
		}
		t.root = lowest
	}
	return t, nil
}

// Root returns the root dir inode. It is 1 by the ingester's convention.
func (t *Tree) Root() uint64 { return t.root }

// PrefetchManifests loads every external subtree manifest reachable from the
// already-loaded manifests, fetching up to concurrency manifests in
// parallel. It exists for backends that walk the whole tree up front
// (erofsadapter.Build): without it, the serial walk pays one network round
// trip per subtree manifest — measured at 389 serial fetches / ~23s for
// python:3.12 over a ~52ms-RTT registry, 93% of cold-start demand latency.
//
// The walk is level-by-level BFS: each round collects the not-yet-loaded
// subtree ids discovered so far and fetches them in parallel; loading a
// manifest indexes its own external subtrees, so the next round discovers
// the next level. Errors are ignored (best effort): a failed subtree stays
// unloaded and the demand path surfaces the error as before.
//
// Gets are tagged chunkstore.SourcePrefetch so access traces classify them
// as prefetch traffic, not workload latency. FUSE mounts should NOT call
// this — lazy per-directory loading is the point of the FUSE backend.
func (t *Tree) PrefetchManifests(ctx context.Context, concurrency int) {
	if concurrency < 1 {
		concurrency = 1
	}
	ctx = chunkstore.WithSource(ctx, chunkstore.SourcePrefetch)
	for {
		t.mu.Lock()
		var batch []chunkstore.ChunkID
		seen := make(map[chunkstore.ChunkID]struct{})
		for _, cid := range t.externalSubtrees {
			if _, loaded := t.manifests[cid]; loaded {
				continue
			}
			if _, flying := t.inflight[cid]; flying {
				continue // completed-with-error entries also live in inflight
			}
			if _, dup := seen[cid]; dup {
				continue
			}
			seen[cid] = struct{}{}
			batch = append(batch, cid)
		}
		t.mu.Unlock()
		if len(batch) == 0 {
			return
		}
		sem := make(chan struct{}, concurrency)
		var wg sync.WaitGroup
		for _, cid := range batch {
			wg.Add(1)
			sem <- struct{}{}
			go func(cid chunkstore.ChunkID) {
				defer wg.Done()
				defer func() { <-sem }()
				_, _ = t.loadManifest(ctx, cid)
			}(cid)
		}
		wg.Wait()
	}
}

// Get resolves inode across all loaded manifests, loading an external subtree
// on demand if the inode is the root of a split subtree that has not yet been
// fetched. Returns ErrNotFound if no loaded manifest and no loadable
// external subtree owns the inode.
func (t *Tree) Get(ctx context.Context, inode uint64) (*NodeInfo, error) {
	if info, ok := t.lookupCached(inode); ok {
		return info, nil
	}
	// The inode may be the root of an external subtree not yet loaded.
	if cid, ok := t.externalSubtreeFor(inode); ok {
		if _, err := t.loadManifest(ctx, cid); err != nil {
			return nil, fmt.Errorf("mount: load external subtree for inode %d: %w", inode, err)
		}
		if info, ok := t.lookupCached(inode); ok {
			return info, nil
		}
	}
	return nil, ErrNotFound
}

// Lookup resolves name within dirInode.
func (t *Tree) Lookup(ctx context.Context, dirInode uint64, name string) (*NodeInfo, error) {
	d, err := t.getDir(ctx, dirInode)
	if err != nil {
		return nil, err
	}
	childInode, ok := d.Entries[name]
	if !ok {
		return nil, ErrNotFound
	}
	return t.Get(ctx, childInode)
}

// ReadDir returns the entries of dirInode sorted by name, with each child's
// kind resolved (loading external subtrees on demand when a child's subtree
// is not yet fetched).
func (t *Tree) ReadDir(ctx context.Context, dirInode uint64) ([]DirEntry, error) {
	d, err := t.getDir(ctx, dirInode)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(d.Entries))
	for n := range d.Entries {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]DirEntry, 0, len(names))
	for _, n := range names {
		childInode := d.Entries[n]
		info, err := t.Get(ctx, childInode)
		if err != nil {
			// All dir entries should resolve; an unresolved child indicates
			// manifest corruption rather than a missing inode.
			return nil, fmt.Errorf("mount: readdir(%d) entry %q: %w", dirInode, n, err)
		}
		out = append(out, DirEntry{Name: n, Inode: childInode, Kind: info.Kind})
	}
	return out, nil
}

// getDir returns the *voilapb.Dir for dirInode, loading any external subtree
// that owns it on demand. Returns ErrNotFound (or an error from a chunk fetch)
// on failure.
func (t *Tree) getDir(ctx context.Context, dirInode uint64) (*voilapb.Dir, error) {
	info, err := t.Get(ctx, dirInode)
	if err != nil {
		return nil, err
	}
	if info.Kind != KindDir || info.Dir == nil {
		return nil, fmt.Errorf("mount: inode %d is not a directory (kind=%v)", dirInode, info.Kind)
	}
	return info.Dir, nil
}

// lookupCached returns the *NodeInfo for inode if it is indexed in any already
// loaded manifest. The caller must NOT hold t.mu.
func (t *Tree) lookupCached(inode uint64) (*NodeInfo, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if d, ok := t.dirByInode[inode]; ok {
		return &NodeInfo{Inode: inode, Kind: KindDir, Dir: d}, true
	}
	if f, ok := t.fileByInode[inode]; ok {
		return &NodeInfo{Inode: inode, Kind: KindFile, File: f}, true
	}
	if s, ok := t.symlinkByInode[inode]; ok {
		return &NodeInfo{Inode: inode, Kind: KindSymlink, Symlink: s}, true
	}
	if dv, ok := t.deviceByInode[inode]; ok {
		return &NodeInfo{Inode: inode, Kind: KindDevice, Device: dv}, true
	}
	return nil, false
}

// externalSubtreeFor returns the (not-yet-loaded) child manifest chunk id that
// owns inode, if any. The caller must NOT hold t.mu.
func (t *Tree) externalSubtreeFor(inode uint64) (chunkstore.ChunkID, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cid, ok := t.externalSubtrees[inode]
	return cid, ok
}

// loadManifest fetches, unmarshals, indexes, and caches the manifest chunk id.
// Concurrent calls for the same id share a single fetch (singleflight).
func (t *Tree) loadManifest(ctx context.Context, id chunkstore.ChunkID) (*voilapb.Manifest, error) {
	t.mu.Lock()
	if m, ok := t.manifests[id]; ok {
		t.mu.Unlock()
		return m, nil
	}
	if e, ok := t.inflight[id]; ok {
		t.mu.Unlock()
		select {
		case <-e.done:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		return e.m, e.err
	}
	e := &inflightEntry{done: make(chan struct{})}
	t.inflight[id] = e
	t.mu.Unlock()

	m, err := t.fetchAndIndex(ctx, id)
	e.m, e.err = m, err
	close(e.done)
	return m, err
}

// fetchAndIndex performs the actual chunk fetch + proto unmarshal and inserts
// the result into the tree indices under t.mu. It is called at most once per
// chunk id (the entry is removed from inflight only when the tree is torn
// down; subsequent callers short-circuit on the manifests cache).
//
// The fetch deliberately drops the caller's cancellation: a subtree manifest
// is a WAN fetch whose result is cached for the lifetime of the mount, and
// the caller's ctx is the per-syscall FUSE request context that go-fuse
// cancels on FUSE_INTERRUPT (a runc path-walk lookup that gets interrupted
// mid-fetch). Tying the fetch to that context aborts the HTTP request with
// "context canceled", leaves the manifest uncached, and surfaces EIO to runc
// — breaking cold-start over a remote registry. context.WithoutCancel drops
// cancellation while KEEPING values, so the chunkstore trace-source tag
// (demand vs prefetch, set by PrefetchManifests) still reaches the store.
// The fetch completes and caches regardless of interruption; the timeout
// only reclaims a goroutine stuck on a dead/stalled connection (the registry
// client's transport bounds the response-header wait, not a mid-body stall).
func (t *Tree) fetchAndIndex(ctx context.Context, id chunkstore.ChunkID) (*voilapb.Manifest, error) {
	fetchCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), manifestFetchTimeout)
	defer cancel()
	data, err := t.store.Get(fetchCtx, id)
	if err != nil {
		return nil, err
	}
	m := &voilapb.Manifest{}
	if err := proto.Unmarshal(data, m); err != nil {
		return nil, fmt.Errorf("mount: unmarshal manifest %s: %w", id, err)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, dup := t.manifests[id]; dup {
		// Another caller raced and indexed this manifest already; nothing to do.
		return m, nil
	}
	t.manifests[id] = m
	t.indexManifestLocked(m)
	return m, nil
}

// indexManifestLocked records every inode the manifest touches into the tree's
// per-inode indices. The caller must hold t.mu.
func (t *Tree) indexManifestLocked(m *voilapb.Manifest) {
	for _, d := range m.Dirs {
		// Only the first manifest to claim an inode wins; ingester guarantees
		// inode uniqueness across the whole tree, so collisions indicate bugs.
		if _, ok := t.dirByInode[d.Inode]; !ok {
			t.dirByInode[d.Inode] = d
		}
	}
	for ino, f := range m.Files {
		if _, ok := t.fileByInode[ino]; !ok {
			t.fileByInode[ino] = f
		}
	}
	for ino, s := range m.Symlinks {
		if _, ok := t.symlinkByInode[ino]; !ok {
			t.symlinkByInode[ino] = s
		}
	}
	for ino, dv := range m.Devices {
		if _, ok := t.deviceByInode[ino]; !ok {
			t.deviceByInode[ino] = dv
		}
	}
	for childInode, chunkBytes := range m.ExternalSubtrees {
		if len(chunkBytes) != len(chunkstore.ChunkID{}) {
			// Malformed but defensive: skip rather than crash.
			continue
		}
		if _, ok := t.externalSubtrees[childInode]; ok {
			continue
		}
		var cid chunkstore.ChunkID
		copy(cid[:], chunkBytes)
		t.externalSubtrees[childInode] = cid
	}
}
