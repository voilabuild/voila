package ingest

import (
	"fmt"
	"sort"

	"voila/internal/chunkstore"
	"voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// ManifestSplitThreshold is the approximate serialized-size limit above which a
// dir subtree is externalized into its own chunk-addressed child Manifest (see
// plan §4.2 "lazy split"). ~64 KiB.
const ManifestSplitThreshold = 64 * 1024

// manifestMode selects how BuildManifest handles NodePendingHardlink nodes.
type manifestMode int

const (
	// manifestMerged is the default mode: a pending hardlink reaching a build
	// is an error (the merge step should have resolved it into a shared inode).
	// Used for the merged-root manifest.
	manifestMerged manifestMode = iota
	// manifestPerLayer emits pending hardlinks as symbolic Manifest.hardlinks
	// entries (Hardlink{inode, target_path}) keeping a Dir entry that points at
	// that inode but no File entry. This makes a per-layer manifest a PURE
	// function of its layer tar: a cross-layer hardlink stays symbolic rather
	// than being materialized against a lower layer.
	manifestPerLayer
)

// AssignInodes walks the tree deterministically (sorted paths) and assigns
// inode numbers starting at 1 for the root dir. Hardlinked files (one *Node
// appearing under multiple names — after pending resolution) share a single
// inode. nlinkOf counts the number of names per inode, which becomes the
// File.nlink value in the emitted manifest.
//
// The returned maps are consumed by the manifest builder.
func AssignInodes(tree *LayerTree) (inodeOf map[*Node]uint64, nlinkOf map[uint64]uint32) {
	inodeOf = make(map[*Node]uint64)
	nlinkOf = make(map[uint64]uint32)
	paths := make([]string, 0, len(tree.byPath))
	for p := range tree.byPath {
		paths = append(paths, p)
	}
	sort.Strings(paths) // "" sorts first → root gets inode 1.
	var next uint64 = 1
	for _, p := range paths {
		n := tree.byPath[p]
		inode, ok := inodeOf[n]
		if !ok {
			inode = next
			inodeOf[n] = inode
			next++
		}
		nlinkOf[inode]++
	}
	return inodeOf, nlinkOf
}

// BuildManifest builds the Manifest for tree, externalizing oversized dir
// subtrees into child Manifests (stored via store.Put) and referencing them
// via external_subtrees. It returns the root Manifest and its
// deterministic-marshaled bytes (the root is NOT stored by BuildManifest; the
// caller stores it).
//
// Pending hardlink nodes (NodePendingHardlink) reaching this build are an
// error — use BuildLayerManifest for per-layer provenance manifests where
// cross-layer hardlinks stay symbolic.
//
// Encoding is deterministic: inodes assigned by a sorted-path walk, dirs
// sorted by inode, and proto marshaled with Deterministic:true so all maps
// (File/Xattrs/Dir.Entries/external_subtrees) emit in stable key order. Two
// runs over the same tree produce identical bytes.
func BuildManifest(tree *LayerTree, store chunkstore.ChunkStore) (*voilapb.Manifest, []byte, error) {
	return buildManifest(tree, store, manifestMerged)
}

// BuildLayerManifest is like BuildManifest but emits NodePendingHardlink
// entries as symbolic Manifest.hardlinks entries (Hardlink{inode, target_path})
// instead of erroring. The Dir entry referencing the pending inode is still
// produced so name → inode resolution round-trips. Used ONLY for per-layer
// provenance manifests; the merged-root manifest must use BuildManifest so an
// unresolved pending hardlink surfaces as a fatal error rather than a silent
// symbolic reference.
func BuildLayerManifest(tree *LayerTree, store chunkstore.ChunkStore) (*voilapb.Manifest, []byte, error) {
	return buildManifest(tree, store, manifestPerLayer)
}

func buildManifest(tree *LayerTree, store chunkstore.ChunkStore, mode manifestMode) (*voilapb.Manifest, []byte, error) {
	inodeOf, nlinkOf := AssignInodes(tree)
	b := &manifestBuilder{store: store, inodeOf: inodeOf, nlinkOf: nlinkOf, mode: mode}
	root, err := b.buildForDir(tree.Root)
	if err != nil {
		return nil, nil, err
	}
	data, err := b.marshal(root)
	if err != nil {
		return nil, nil, err
	}
	return root, data, nil
}

// BuildAndStoreManifest builds the merged-root manifest for tree and stores
// its marshaled bytes as a chunk, returning the chunk id. Pending hardlink
// nodes are an error in this path.
func BuildAndStoreManifest(tree *LayerTree, store chunkstore.ChunkStore) (chunkstore.ChunkID, error) {
	return buildAndStoreManifest(tree, store, manifestMerged)
}

// BuildAndStoreLayerManifest builds the per-layer provenance manifest for
// tree (with symbolic Hardlink entries for unresolved cross-layer hardlinks)
// and stores its marshaled bytes as a chunk, returning the chunk id.
func BuildAndStoreLayerManifest(tree *LayerTree, store chunkstore.ChunkStore) (chunkstore.ChunkID, error) {
	return buildAndStoreManifest(tree, store, manifestPerLayer)
}

func buildAndStoreManifest(tree *LayerTree, store chunkstore.ChunkStore, mode manifestMode) (chunkstore.ChunkID, error) {
	_, data, err := buildManifest(tree, store, mode)
	if err != nil {
		return chunkstore.ChunkID{}, err
	}
	return store.Put(data)
}

// manifestBuilder carries the per-tree inode/nlink maps and the store used to
// externalize split subtrees.
type manifestBuilder struct {
	store   chunkstore.ChunkStore
	inodeOf map[*Node]uint64
	nlinkOf map[uint64]uint32
	mode    manifestMode
}

// childBuildResult is a child dir's fully-built manifest and its marshaled
// bytes (used both for inlining and for externalizing-into-store).
type childBuildResult struct {
	node *Node
	m    *voilapb.Manifest
	data []byte
}

// buildForDir returns the Manifest representing dir D's subtree, with any
// oversized child dirs externalized (their manifests stored as chunks and
// referenced via external_subtrees). It does NOT store D's own manifest — that
// is the parent's responsibility (the top-level caller stores the root).
func (b *manifestBuilder) buildForDir(D *Node) (*voilapb.Manifest, error) {
	// Recurse into child dirs (sorted by name for determinism).
	childDirs := sortedChildDirs(D)
	children := make([]childBuildResult, 0, len(childDirs))
	for _, c := range childDirs {
		mc, err := b.buildForDir(c)
		if err != nil {
			return nil, err
		}
		data, err := b.marshal(mc)
		if err != nil {
			return nil, err
		}
		children = append(children, childBuildResult{node: c, m: mc, data: data})
	}

	inlined := make(map[*Node]bool, len(children))
	childByNode := make(map[*Node]*childBuildResult, len(children))
	for i := range children {
		inlined[children[i].node] = true
		childByNode[children[i].node] = &children[i]
	}
	externalChunk := make(map[*Node][]byte)

	// assemble builds the manifest for D with the current inlined/externalized
	// split. Returns the manifest and its marshaled bytes.
	assemble := func() (*voilapb.Manifest, []byte, error) {
		m := &voilapb.Manifest{
			Files:            make(map[uint64]*voilapb.File),
			Symlinks:         make(map[uint64]*voilapb.Symlink),
			Devices:          make(map[uint64]*voilapb.Device),
			ExternalSubtrees: make(map[uint64][]byte),
		}
		if b.mode == manifestPerLayer {
			m.Hardlinks = make(map[uint64]*voilapb.Hardlink)
		}
		dDir := b.dirProto(D)
		m.Dirs = append(m.Dirs, dDir)
		for _, name := range sortedNamesOf(D.Children) {
			child := D.Children[name]
			childInode := b.inodeOf[child]
			dDir.Entries[name] = childInode
			switch child.Type {
			case NodeDir:
				if inlined[child] {
					if err := mergeManifest(m, childByNode[child].m); err != nil {
						return nil, nil, err
					}
				} else {
					m.ExternalSubtrees[childInode] = externalChunk[child]
				}
			case NodeRegular:
				m.Files[childInode] = b.fileProto(child, childInode)
			case NodeSymlink:
				m.Symlinks[childInode] = b.symlinkProto(child, childInode)
			case NodeDevice:
				m.Devices[childInode] = b.deviceProto(child, childInode)
			case NodePendingHardlink:
				if b.mode == manifestPerLayer {
					m.Hardlinks[childInode] = &voilapb.Hardlink{
						Inode:      childInode,
						TargetPath: child.LinkTarget,
					}
				} else {
					return nil, nil, fmt.Errorf(
						"ingest: unresolved pending hardlink at %q (target %q) reached manifest build",
						child.Path, child.LinkTarget)
				}
			}
		}
		data, err := b.marshal(m)
		if err != nil {
			return nil, nil, err
		}
		return m, data, nil
	}

	m, data, err := assemble()
	if err != nil {
		return nil, err
	}

	// Externalize largest inlined child dirs until the manifest fits or no
	// inlined child dirs remain. Stored manifests are referenced from the
	// parent's external_subtrees.
	for len(data) > ManifestSplitThreshold {
		best := pickLargestInlinedChild(children, inlined)
		if best == nil {
			// No inlined child dirs left to externalize; cannot split further.
			break
		}
		chunkID, err := b.store.Put(childByNode[best].data)
		if err != nil {
			return nil, err
		}
		externalChunk[best] = append([]byte(nil), chunkID[:]...)
		inlined[best] = false
		m, data, err = assemble()
		if err != nil {
			return nil, err
		}
	}
	return m, nil
}

// pickLargestInlinedChild returns the inlined child whose own manifest marshals
// to the most bytes (so externalizing it shrinks the parent the most). nil when
// nothing remains to externalize.
func pickLargestInlinedChild(children []childBuildResult, inlined map[*Node]bool) *Node {
	var best *Node
	bestSize := -1
	for i := range children {
		c := &children[i]
		if !inlined[c.node] {
			continue
		}
		if len(c.data) > bestSize {
			bestSize = len(c.data)
			best = c.node
		}
	}
	return best
}

// mergeManifest merges src into dst (dirs appended; files/symlinks/devices/
// external_subtrees/hardlinks copied). Both represent a contiguous subtree each
// rooted at distinct dirs, so no key collisions occur across inlined children.
// In manifestMerged mode the Hardlinks maps are nil and the copy is a no-op.
func mergeManifest(dst, src *voilapb.Manifest) error {
	dst.Dirs = append(dst.Dirs, src.Dirs...)
	for k, v := range src.Files {
		dst.Files[k] = v
	}
	for k, v := range src.Symlinks {
		dst.Symlinks[k] = v
	}
	for k, v := range src.Devices {
		dst.Devices[k] = v
	}
	for k, v := range src.ExternalSubtrees {
		dst.ExternalSubtrees[k] = v
	}
	for k, v := range src.Hardlinks {
		dst.Hardlinks[k] = v
	}
	return nil
}

// marshal returns the deterministic-marshaled bytes of m, sorting the repeated
// dirs by inode for stable wire output (proto deterministic sorts map keys but
// not repeated message fields, so we sort dirs ourselves).
func (b *manifestBuilder) marshal(m *voilapb.Manifest) ([]byte, error) {
	sort.Slice(m.Dirs, func(i, j int) bool {
		return m.Dirs[i].Inode < m.Dirs[j].Inode
	})
	return proto.MarshalOptions{Deterministic: true}.MarshalAppend(nil, m)
}

// sortedChildDirs returns D's child *Nodes that are dirs, sorted by name.
func sortedChildDirs(D *Node) []*Node {
	var out []*Node
	for _, name := range sortedNamesOf(D.Children) {
		if D.Children[name].Type == NodeDir {
			out = append(out, D.Children[name])
		}
	}
	return out
}

func (b *manifestBuilder) dirProto(n *Node) *voilapb.Dir {
	return &voilapb.Dir{
		Inode:   b.inodeOf[n],
		Mode:    n.Mode & 0o7777,
		Uid:     n.Uid,
		Gid:     n.Gid,
		MtimeNs: n.MtimeNs,
		Entries: make(map[string]uint64),
	}
}

func (b *manifestBuilder) fileProto(n *Node, inode uint64) *voilapb.File {
	f := &voilapb.File{
		Inode:   inode,
		Mode:    n.Mode & 0o7777,
		Uid:     n.Uid,
		Gid:     n.Gid,
		Size:    n.Size,
		MtimeNs: n.MtimeNs,
		Nlink:   b.nlinkOf[inode],
		Xattrs:  make(map[string][]byte, len(n.Xattrs)),
		Blocks:  n.Blocks,
	}
	for k, v := range n.Xattrs {
		f.Xattrs[k] = append([]byte(nil), v...)
	}
	return f
}

func (b *manifestBuilder) symlinkProto(n *Node, inode uint64) *voilapb.Symlink {
	return &voilapb.Symlink{
		Inode:  inode,
		Target: n.Target,
		Uid:    n.Uid,
		Gid:    n.Gid,
	}
}

func (b *manifestBuilder) deviceProto(n *Node, inode uint64) *voilapb.Device {
	return &voilapb.Device{
		Inode:     inode,
		Mode:      n.Mode & 0o7777,
		Uid:       n.Uid,
		Gid:       n.Gid,
		RdevMajor: n.Major,
		RdevMinor: n.Minor,
		IsChar:    n.CharDevice,
	}
}
