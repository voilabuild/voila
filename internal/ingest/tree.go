// Package ingest turns OCI/docker tarballs into chunk-addressed manifests.
//
// This file defines the in-memory per-layer tree types used by layer_walk.go
// (and later by merge.go and manifest.go). The tree is metadata-only: regular
// file contents live in the chunk store, referenced by the Block list on each
// file node.
package ingest

import (
	"voila/internal/proto"
)

// NodeType discriminates the kinds of filesystem entries a layer can contain.
type NodeType int

const (
	NodeRegular NodeType = iota
	NodeDir
	NodeSymlink
	NodeDevice
	// NodePendingHardlink is a tar hardlink (TypeLink) whose target has not yet
	// been seen in this layer. It carries the unresolved LinkTarget (cleaned,
	// relative to rootfs) so merge.go can resolve it against the merged lower
	// tree; if it remains unresolved after merge, that is an error.
	NodePendingHardlink
)

// Node is one entry in a per-layer tree. Hardlinked regular files share a
// single *Node across multiple names (both names' parent dir.Children point at
// the same *Node), mirroring the inode-sharing that voilapb.Manifest expresses
// via Dir.entries name→inode.
type Node struct {
	// Path is the cleaned path relative to rootfs, with no leading "./". The
	// root directory has Path "". For a hardlinked file, Path is the path of
	// the link target encountered first in the layer's tar; subsequent links
	// attach under their own names but share this node.
	Path string
	// Name is the base name within the parent dir. For the root dir it is "".
	Name string

	Type NodeType

	Mode    uint32
	Uid     uint32
	Gid     uint32
	MtimeNs uint64

	// Xattrs maps fully-qualified xattr name → raw value (PAX SCHILY.xattr.*
	// records, prefix stripped). Only populated for regular files.
	Xattrs map[string][]byte

	// Regular files:
	Size   uint64
	Blocks []*voilapb.Block

	// Symlinks (NodeSymlink): target string.
	Target string

	// Devices (NodeDevice): major/minor and char-vs-block discriminator.
	Major      uint32
	Minor      uint32
	CharDevice bool

	// Pending hardlinks (NodePendingHardlink): the cleaned link target path,
	// relative to rootfs, that this entry should resolve to at merge time.
	LinkTarget string

	// Nlink is the number of names pointing at this node. >1 means hardlinked.
	Nlink uint32

	// Children maps base name → child *Node for NodeDir. A hardlinked regular
	// file may appear as a child under more than one name in *different* parent
	// dirs (each parent's map entry points at the same *Node).
	Children map[string]*Node

	// Whiteout / opaque markers per layer. These do not produce nodes but are
	// recorded on the owning dir node for convenience; see whiteouts.go.
	Whiteouts  []WhiteoutEntry
	OpaqueMark bool

	// Implicit marks a dir fabricated by ensureDir because the tar referenced a
	// path beneath it without listing the dir itself. Implicit dirs carry
	// placeholder metadata (0755 root:root) that must never override a lower
	// layer's real metadata at merge time.
	Implicit bool
}

// LayerTree is the in-memory representation of one OCI/docker layer's
// filesystem, produced by layer_walk.go. It is consumed by merge.go and
// manifest.go (added in later phases).
type LayerTree struct {
	// Root is the root directory node (Path "").
	Root *Node
	// byPath indexes every node this layer introduced by its canonical path.
	// Hardlink duplicates (a second name for an already-seen regular file) are
	// NOT inserted here with the duplicate name — the first name wins. Use
	// Lookup to resolve a link target by path.
	byPath map[string]*Node

	// Whiteouts counts and records explicit (.wh.<name>) whiteouts in this
	// layer; OpaqueDirs lists the dir paths carrying an opaque (.wh..wh..opq)
	// marker. Counts are surfaced in the layer result for later aggregation.
	Whiteouts  []WhiteoutEntry
	OpaqueDirs []string
	WhiteoutsN uint64
	OpaqueN    uint64
}

// Lookup returns the node at the given cleaned path, or nil if absent. The
// path must be cleaned and relative to rootfs (as produced by cleanEntryPath).
func (t *LayerTree) Lookup(p string) *Node {
	if t.byPath == nil {
		return nil
	}
	return t.byPath[p]
}

// EachNode calls fn for every path in the tree. Returning false stops iteration.
func (t *LayerTree) EachNode(fn func(path string, n *Node) bool) {
	if t.byPath == nil {
		return
	}
	for p, n := range t.byPath {
		if !fn(p, n) {
			return
		}
	}
}

// Put records a node under its Path. It assumes the path is unique within the
// layer (i.e. the same path has not already been Put). Hardlink duplicates are
// attached via attachHardlink, not via Put.
func (t *LayerTree) Put(n *Node) {
	if t.byPath == nil {
		t.byPath = make(map[string]*Node)
	}
	if n.Path != "" {
		t.byPath[n.Path] = n
	} else {
		t.byPath[""] = n
	}
}

// NewTree returns an empty LayerTree with its root directory node initialized.
func NewTree() *LayerTree {
	root := &Node{
		Path:     "",
		Name:     "",
		Type:     NodeDir,
		Mode:     0o755,
		Children: make(map[string]*Node),
		Implicit: true, // cleared if the tar carries an explicit "./" entry
	}
	t := &LayerTree{Root: root}
	t.Put(root)
	return t
}
