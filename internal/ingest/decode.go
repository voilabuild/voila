// Package ingest's decode.go implements DecodeTree, the inverse of
// BuildLayerManifest: given the chunk id of a per-layer manifest (as produced
// by BuildAndStoreLayerManifest), it fetches the manifest and every
// external_subtrees chunk transitively and reconstructs the in-memory
// LayerTree. Symbolic Manifest.hardlinks entries become NodePendingHardlink
// nodes carrying the original LinkTarget.
//
// The round-trip property is: walk a layer tar → tree A →
// BuildAndStoreLayerManifest → DecodeTree → tree B → BuildLayerManifest(B)
// yields byte-identical manifest bytes. This holds because BuildLayerManifest
// is deterministic (sorted-path inode assignment + deterministic proto marshal
// + deterministic external-subtree split), and DecodeTree reproduces the same
// byPath shape and same per-inode sharing pattern that walk produced.
package ingest

import (
	"context"
	"fmt"
	"sort"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// DecodeTree fetches the per-layer manifest stored at manifestChunk and every
// external_subtrees chunk transitively, and reconstructs the in-memory
// LayerTree. Multi-name inodes (within-layer hardlinks) become a single
// *Node referenced under multiple names with nlink preserved; Manifest.hardlinks
// entries become NodePendingHardlink nodes carrying the original LinkTarget.
//
// The returned tree's byPath is fully populated (every name from every
// Dir.Entries). Inodes in the reconstructed manifest are NOT taken from the
// manifest; AssignInodes will re-derive them deterministically when
// BuildLayerManifest runs on the decoded tree, yielding byte-identical
// manifest bytes for the round-trip property.
func DecodeTree(ctx context.Context, store chunkstore.ChunkStore, manifestChunk chunkstore.ChunkID) (*LayerTree, error) {
	if store == nil {
		return nil, fmt.Errorf("ingest: nil chunk store")
	}
	d := &decoder{ctx: ctx, store: store,
		dirs:      map[uint64]*voilapb.Dir{},
		files:     map[uint64]*voilapb.File{},
		symlinks:  map[uint64]*voilapb.Symlink{},
		devices:   map[uint64]*voilapb.Device{},
		hardlinks: map[uint64]*voilapb.Hardlink{},
		loaded:    map[chunkstore.ChunkID]bool{},
	}
	if err := d.loadManifest(manifestChunk); err != nil {
		return nil, err
	}
	return d.buildTree()
}

// decoder accumulates Dir/File/Symlink/Device/Hardlink entries across the root
// manifest and every external_subtrees chunk fetched transitively. Inodes are
// globally unique in a layer manifest, so a single set of maps keyed by inode
// covers the whole tree regardless of which chunk an entry was defined in.
type decoder struct {
	ctx   context.Context
	store chunkstore.ChunkStore

	dirs      map[uint64]*voilapb.Dir
	files     map[uint64]*voilapb.File
	symlinks  map[uint64]*voilapb.Symlink
	devices   map[uint64]*voilapb.Device
	hardlinks map[uint64]*voilapb.Hardlink

	loaded map[chunkstore.ChunkID]bool
}

// loadManifest fetches + unmarshals one manifest chunk, merges its entries
// into the global maps, and recurses into external_subtrees. The visited set
// guards against two externalized subtrees referencing the same chunk (it
// would be wasteful but, more importantly, must not infinite-loop on a cycle
// — even though the writer never emits one).
func (d *decoder) loadManifest(id chunkstore.ChunkID) error {
	if d.loaded[id] {
		return nil
	}
	d.loaded[id] = true

	data, err := d.store.Get(d.ctx, id)
	if err != nil {
		return fmt.Errorf("ingest: decode manifest %s: %w", id, err)
	}
	m := &voilapb.Manifest{}
	if err := proto.Unmarshal(data, m); err != nil {
		return fmt.Errorf("ingest: unmarshal manifest %s: %w", id, err)
	}
	for _, dir := range m.GetDirs() {
		if _, dup := d.dirs[dir.GetInode()]; dup {
			return fmt.Errorf("ingest: duplicate Dir inode %d across manifest chunks", dir.GetInode())
		}
		d.dirs[dir.GetInode()] = dir
	}
	for k, v := range m.GetFiles() {
		if _, dup := d.files[k]; dup {
			return fmt.Errorf("ingest: duplicate File inode %d across manifest chunks", k)
		}
		d.files[k] = v
	}
	for k, v := range m.GetSymlinks() {
		if _, dup := d.symlinks[k]; dup {
			return fmt.Errorf("ingest: duplicate Symlink inode %d across manifest chunks", k)
		}
		d.symlinks[k] = v
	}
	for k, v := range m.GetDevices() {
		if _, dup := d.devices[k]; dup {
			return fmt.Errorf("ingest: duplicate Device inode %d across manifest chunks", k)
		}
		d.devices[k] = v
	}
	for k, v := range m.GetHardlinks() {
		if _, dup := d.hardlinks[k]; dup {
			return fmt.Errorf("ingest: duplicate Hardlink inode %d across manifest chunks", k)
		}
		d.hardlinks[k] = v
	}
	for _, raw := range m.GetExternalSubtrees() {
		cid, ok := chunkIDFromBytes(raw)
		if !ok {
			return fmt.Errorf("ingest: external_subtrees entry is not 32 bytes")
		}
		if err := d.loadManifest(cid); err != nil {
			return err
		}
	}
	return nil
}

// buildTree materializes the in-memory LayerTree from the merged entries. It
// starts at the root Dir (inode 1, the convention AssignInodes guarantees
// since "" sorts first) and walks every (name, childInode) entry,
// constructing the corresponding walked-style Node and recursing into dir
// children.
func (d *decoder) buildTree() (*LayerTree, error) {
	rootDir, ok := d.dirs[1]
	if !ok {
		return nil, fmt.Errorf("ingest: manifest has no root Dir (inode 1)")
	}
	tree := NewTree()
	// Overwrite NewTree's placeholder root with the manifest's root metadata
	// so mode/uid/gid/mtime round-trip exactly.
	applyDirMeta(tree.Root, rootDir)

	// inodeToNode caches a *Node the first time its inode is materialized, so
	// multi-name inodes (within-layer hardlinks) share one *Node across every
	// name in byPath — mirroring layer_walk's walkEntry sharing pattern.
	inodeToNode := map[uint64]*Node{1: tree.Root}
	if err := d.populateDir(tree, tree.Root, "", rootDir, inodeToNode, map[string]bool{}); err != nil {
		return nil, err
	}
	return tree, nil
}

// populateDir materializes every child of dir (the protobuf Dir) under parent
// (its *Node in the tree). dirPath is the parent's Path ("" for root). The
// visited map guards against cycles in corrupt manifests.
func (d *decoder) populateDir(tree *LayerTree, parent *Node, dirPath string, dir *voilapb.Dir, inodeToNode map[uint64]*Node, visited map[string]bool) error {
	if visited[dirPath] {
		return fmt.Errorf("ingest: cycle detected at %q during decode", dirPath)
	}
	visited[dirPath] = true

	// Walk Dir.Entries in sorted name order so the reconstructed tree's
	// child map are filled deterministically; AssignInodes re-sorts byPath
	// anyway, but sorted traversal keeps byPath insertion order clean.
	names := make([]string, 0, len(dir.GetEntries()))
	for n := range dir.GetEntries() {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		childInode := dir.GetEntries()[name]
		childPath := name
		if dirPath != "" {
			childPath = dirPath + "/" + name
		}
		// Reuse a shared *Node if this inode was already materialized
		// (within-layer hardlink: same File inode under two names).
		if existing, ok := inodeToNode[childInode]; ok {
			attachChild(parent, name, existing)
			if tree.byPath != nil && tree.byPath[childPath] == nil {
				tree.byPath[childPath] = existing
			}
			continue
		}
		node, isDir, err := d.materializeNode(childInode, name, childPath)
		if err != nil {
			return err
		}
		inodeToNode[childInode] = node
		attachChild(parent, name, node)
		tree.Put(node)
		if isDir {
			childDir := d.dirs[childInode]
			if childDir == nil {
				return fmt.Errorf("ingest: child inode %d referenced as a dir from %q but has no Dir entry",
					childInode, dirPath)
			}
			if err := d.populateDir(tree, node, childPath, childDir, inodeToNode, visited); err != nil {
				return err
			}
		}
	}
	return nil
}

// materializeNode builds a *Node for the given inode based on which global map
// defines it: File → NodeRegular, Symlink → NodeSymlink, Device → NodeDevice,
// Hardlink → NodePendingHardlink, Dir → NodeDir. isDir is true for NodeDir so
// the caller recurses into the child's entries (the Dir's own Dir proto is
// fetched separately from the global map by the caller).
func (d *decoder) materializeNode(inode uint64, name, fullPath string) (*Node, bool, error) {
	switch {
	case d.files[inode] != nil:
		f := d.files[inode]
		n := &Node{
			Path:    fullPath,
			Name:    name,
			Type:    NodeRegular,
			Mode:    f.GetMode(),
			Uid:     f.GetUid(),
			Gid:     f.GetGid(),
			Size:    f.GetSize(),
			MtimeNs: f.GetMtimeNs(),
			Nlink:   f.GetNlink(),
			Blocks:  f.GetBlocks(),
		}
		if len(f.GetXattrs()) > 0 {
			n.Xattrs = make(map[string][]byte, len(f.GetXattrs()))
			for k, v := range f.GetXattrs() {
				n.Xattrs[k] = append([]byte(nil), v...)
			}
		}
		// Proto Blocks are shared with the unmarshaled message; deepcopy so
		// the decoded tree is independent of the manifest bytes lifecycle.
		if len(n.Blocks) > 0 {
			blocks := make([]*voilapb.Block, len(n.Blocks))
			for i, b := range n.Blocks {
				blocks[i] = &voilapb.Block{
					OffsetInFile: b.GetOffsetInFile(),
					ChunkId:      append([]byte(nil), b.GetChunkId()...),
					LogicalLen:   b.GetLogicalLen(),
				}
			}
			n.Blocks = blocks
		}
		return n, false, nil
	case d.symlinks[inode] != nil:
		s := d.symlinks[inode]
		return &Node{
			Path:   fullPath,
			Name:   name,
			Type:   NodeSymlink,
			Target: s.GetTarget(),
			Mode:   0o777,
			Uid:    s.GetUid(),
			Gid:    s.GetGid(),
			Nlink:  1,
		}, false, nil
	case d.devices[inode] != nil:
		dev := d.devices[inode]
		return &Node{
			Path:       fullPath,
			Name:       name,
			Type:       NodeDevice,
			Mode:       dev.GetMode(),
			Uid:        dev.GetUid(),
			Gid:        dev.GetGid(),
			Major:      dev.GetRdevMajor(),
			Minor:      dev.GetRdevMinor(),
			CharDevice: dev.GetIsChar(),
			Nlink:      1,
		}, false, nil
	case d.hardlinks[inode] != nil:
		h := d.hardlinks[inode]
		return &Node{
			Path:       fullPath,
			Name:       name,
			Type:       NodePendingHardlink,
			LinkTarget: h.GetTargetPath(),
			Nlink:      1,
		}, false, nil
	case d.dirs[inode] != nil:
		dd := d.dirs[inode]
		n := &Node{
			Path:     fullPath,
			Name:     name,
			Type:     NodeDir,
			Mode:     dd.GetMode(),
			Uid:      dd.GetUid(),
			Gid:      dd.GetGid(),
			MtimeNs:  dd.GetMtimeNs(),
			Nlink:    1,
			Children: make(map[string]*Node),
		}
		return n, true, nil
	default:
		return nil, false, fmt.Errorf("ingest: inode %d referenced from Dir.Entries has no Dir/File/Symlink/Device/Hardlink entry", inode)
	}
}

// applyDirMeta copies shared dir metadata from a protobuf Dir onto a *Node
// (the tree root), matching the field set BuildManifest emits.
func applyDirMeta(n *Node, d *voilapb.Dir) {
	n.Type = NodeDir
	if d.GetMode() != 0 {
		n.Mode = d.GetMode()
	}
	n.Uid = d.GetUid()
	n.Gid = d.GetGid()
	if d.GetMtimeNs() != 0 {
		n.MtimeNs = d.GetMtimeNs()
	}
	n.Nlink = 1
	n.Implicit = false
	if n.Children == nil {
		n.Children = make(map[string]*Node)
	}
}
