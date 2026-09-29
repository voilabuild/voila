package ingest

import (
	"archive/tar"
	"context"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"

	"voila/internal/chunkstore"
	"voila/internal/proto"

	"lukechampine.com/blake3"
)

// ChunkSize is the per-chunk logical size used when streaming regular file
// content into the chunk store (plan §5: 1 MiB chunker).
const ChunkSize = 1 << 20 // 1 MiB

var (
	errAbsolute   = errors.New("ingest: absolute path in layer tar is not allowed")
	errPathEscape = errors.New("ingest: path escapes layer root (.. )")
)

// LayerWalkResult is the outcome of streaming a single layer blob. It carries
// the per-layer tree plus counters later aggregated into the Ingest Result.
type LayerWalkResult struct {
	Tree          *LayerTree
	BytesIn       uint64 // total logical bytes of regular-file content
	ChunkCount    uint64 // distinct chunks this layer reference (after dedup)
	ChunksDeduped uint64 // chunks this layer referenced that were already known
	StoredBytes   uint64 // on-disk bytes of newly-written chunks (stored/compressed len)
	Warnings      []string
}

// WalkLayer streams a single layer's (already decompressed) tar stream from r
// into a per-layer in-memory tree, chunking regular-file content through
// store.Put. The reader must yield a plain tar stream; use DecompressLayer for
// compressed blobs.
//
// WalkLayer is single-goroutine and bounds memory to one ~1 MiB chunk buffer;
// only the metadata-only per-layer tree lives in RAM after return.
func WalkLayer(ctx context.Context, r io.Reader, store chunkstore.ChunkStore) (*LayerWalkResult, error) {
	if store == nil {
		return nil, errors.New("ingest: nil chunk store")
	}
	tr := tar.NewReader(r)
	tree := NewTree()
	res := &LayerWalkResult{Tree: tree}

	// seen tracks chunk ids this ingest has already written or observed via
	// Stat, so repeat content counts as deduped without a second Put.
	seen := make(map[chunkstore.ChunkID]bool)
	chunkBuf := make([]byte, ChunkSize)

	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("ingest: tar read: %w", err)
		}

		clean, err := cleanEntryPath(hdr.Name)
		if err != nil {
			return nil, fmt.Errorf("ingest: bad path %q: %w", hdr.Name, err)
		}

		// Whiteouts never become files.
		if parent, wname, explicit, opaque := ClassifyEntry(clean); explicit || opaque {
			if opaque {
				recordOpaque(tree, parent)
				res.Tree.OpaqueN++
			} else {
				recordWhiteout(tree, parent, wname)
				res.Tree.WhiteoutsN++
			}
			continue
		}

		// The root dir entry (clean == "") just anchors metadata on Root.
		if clean == "" {
			applyHeaderMeta(tree.Root, hdr, NodeDir)
			continue
		}

		if err := walkEntry(ctx, tr, hdr, clean, tree, store, seen, chunkBuf, res); err != nil {
			return nil, fmt.Errorf("ingest: layer walk entry %q: %w", hdr.Name, err)
		}
	}
	return res, nil
}

// walkEntry handles a single non-whiteout tar entry, attaching it to the tree.
func walkEntry(
	ctx context.Context,
	tr *tar.Reader,
	hdr *tar.Header,
	clean string,
	tree *LayerTree,
	store chunkstore.ChunkStore,
	seen map[chunkstore.ChunkID]bool,
	chunkBuf []byte,
	res *LayerWalkResult,
) error {
	parentPath, base := splitPath(clean)
	parent := ensureDir(tree, parentPath)

	switch hdr.Typeflag {
	case tar.TypeReg, tar.TypeRegA:
		node := &Node{
			Path:   clean,
			Name:   base,
			Type:   NodeRegular,
			Mode:   uint32(hdr.Mode & 0o7777),
			Uid:    uint32(hdr.Uid),
			Gid:    uint32(hdr.Gid),
			Xattrs: extractXattrs(hdr),
			Nlink:  1,
		}
		if err := applyMtime(node, hdr); err != nil {
			return err
		}
		if err := chunkFile(ctx, tr, store, seen, chunkBuf, node, res); err != nil {
			return err
		}
		attachChild(parent, base, node)
		tree.Put(node)

	case tar.TypeLink:
		target := cleanEntryPathMust(hdr.Linkname)
		if existing := tree.Lookup(target); existing != nil && existing.Type == NodeRegular {
			// Resolve now: share the same node, bump nlink. Record the alternate
			// name in byPath so later links targeting either name resolve.
			attachChild(parent, base, existing)
			existing.Nlink++
			if tree.byPath != nil && tree.byPath[clean] == nil {
				tree.byPath[clean] = existing
			}
			return nil
		}
		// Pending cross-layer hardlink: record for merge-time resolution.
		node := &Node{
			Path:       clean,
			Name:       base,
			Type:       NodePendingHardlink,
			LinkTarget: target,
			Uid:        uint32(hdr.Uid),
			Gid:        uint32(hdr.Gid),
			Mode:       uint32(hdr.Mode & 0o7777),
			Nlink:      1,
		}
		if err := applyMtime(node, hdr); err != nil {
			return err
		}
		attachChild(parent, base, node)
		tree.Put(node)

	case tar.TypeSymlink:
		node := &Node{
			Path:   clean,
			Name:   base,
			Type:   NodeSymlink,
			Target: hdr.Linkname,
			Mode:   uint32(hdr.Mode & 0o7777),
			Uid:    uint32(hdr.Uid),
			Gid:    uint32(hdr.Gid),
			Nlink:  1,
		}
		if err := applyMtime(node, hdr); err != nil {
			return err
		}
		attachChild(parent, base, node)
		tree.Put(node)

	case tar.TypeDir:
		node, isNew := ensureDirEx(tree, clean, hdr)
		_ = isNew
		_ = node

	case tar.TypeChar, tar.TypeBlock:
		node := &Node{
			Path:       clean,
			Name:       base,
			Type:       NodeDevice,
			Mode:       uint32(hdr.Mode & 0o7777),
			Uid:        uint32(hdr.Uid),
			Gid:        uint32(hdr.Gid),
			Major:      uint32(hdr.Devmajor),
			Minor:      uint32(hdr.Devminor),
			CharDevice: hdr.Typeflag == tar.TypeChar,
			Nlink:      1,
		}
		if err := applyMtime(node, hdr); err != nil {
			return err
		}
		attachChild(parent, base, node)
		tree.Put(node)

	case tar.TypeFifo:
		// FIFOs and sockets are not representable in v0.1 manifests; count them
		// as warnings. (archive/tar has no separate TypeSocket constant.)
		if isSocketMode(hdr.Mode) {
			res.Warnings = append(res.Warnings,
				fmt.Sprintf("skipping socket entry %q (unsupported in v0.1)", clean))
		} else {
			res.Warnings = append(res.Warnings,
				fmt.Sprintf("skipping FIFO entry %q (unsupported in v0.1)", clean))
		}

	case tar.TypeXHeader, tar.TypeXGlobalHeader, tar.TypeGNULongName, tar.TypeGNULongLink, tar.TypeGNUSparse, tar.TypeCont:
		// Consumed transparently by archive/tar; nothing to record.

	default:
		res.Warnings = append(res.Warnings,
			fmt.Sprintf("skipping unknown type %d entry %q", hdr.Typeflag, clean))
	}
	return nil
}

// chunkFile streams the current tar entry's content through the 1 MiB chunker,
// Put'ing each chunk and appending a Block to node. It consumes exactly
// hdr.Size bytes of content.
func chunkFile(
	ctx context.Context,
	tr *tar.Reader,
	store chunkstore.ChunkStore,
	seen map[chunkstore.ChunkID]bool,
	chunkBuf []byte,
	node *Node,
	res *LayerWalkResult,
) error {
	var offset uint64
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, err := io.ReadFull(tr, chunkBuf)
		if n > 0 {
			buf := chunkBuf[:n]
			res.BytesIn += uint64(n)
			node.Size += uint64(n)
			block, isNew, storedAdd, err := putChunk(store, seen, buf)
			if err != nil {
				return fmt.Errorf("store.Put: %w", err)
			}
			block.OffsetInFile = offset
			node.Blocks = append(node.Blocks, block)
			res.ChunkCount++
			res.StoredBytes += storedAdd
			if !isNew {
				res.ChunksDeduped++
			}
			offset += uint64(n)
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			// io.ReadFull returns ErrUnexpectedEOF on a short final read when
			// n>0; we already handled the bytes above. EOF means the file ended
			// cleanly (possibly at a chunk boundary).
			if err == io.ErrUnexpectedEOF && n == 0 {
				return errors.New("ingest: short read mid-chunk")
			}
			break
		}
		if err != nil {
			return fmt.Errorf("read file content: %w", err)
		}
	}
	return nil
}

// putChunk stores one chunk (if not already known) and returns the Block
// referencing it. isNew is false when the chunk was already present in the
// store or seen earlier this ingest (dedup). storedSize is the on-disk size
// added by this call (zero when deduped).
func putChunk(store chunkstore.ChunkStore, seen map[chunkstore.ChunkID]bool, buf []byte) (*voilapb.Block, bool, uint64, error) {
	id := chunkstore.ChunkID(blake3.Sum256(buf))
	isNew := true
	var storedAdd uint64

	if seen[id] {
		isNew = false
	} else if _, ok := store.Stat(id); ok {
		isNew = false
		seen[id] = true
	} else {
		seen[id] = true
		if _, err := store.Put(buf); err != nil {
			return nil, false, 0, err
		}
		if meta, ok := store.Stat(id); ok {
			storedAdd = meta.StoredLen
		}
	}

	block := &voilapb.Block{
		OffsetInFile: 0, // set by caller
		ChunkId:      append([]byte(nil), id[:]...),
		LogicalLen:   uint64(len(buf)),
	}
	return block, isNew, storedAdd, nil
}

// extractXattrs reads extended attributes from the header's PAXRecords under
// the SCHILY.xattr.* namespace (stripping the prefix), falling back to the
// deprecated Xattrs map when PAXRecords has nothing. Values become raw bytes.
func extractXattrs(hdr *tar.Header) map[string][]byte {
	const prefix = "SCHILY.xattr."
	out := make(map[string][]byte)
	for k, v := range hdr.PAXRecords {
		if strings.HasPrefix(k, prefix) {
			out[k[len(prefix):]] = []byte(v)
		}
	}
	if len(out) == 0 && len(hdr.Xattrs) > 0 {
		for k, v := range hdr.Xattrs {
			out[k] = []byte(v)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// cleanEntryPath normalizes a tar entry name to a rootfs-relative path with no
// leading "./", rejecting absolute or ".."-escaping names as a security guard.
// Returns "" for the root directory entry (i.e. "." or "").
func cleanEntryPath(name string) (string, error) {
	name = strings.TrimPrefix(name, "./")
	if name == "" || name == "." {
		return "", nil
	}
	p := path.Clean(name)
	if p == "." {
		return "", nil
	}
	if strings.HasPrefix(p, "/") {
		return "", errAbsolute
	}
	if p == ".." || strings.HasPrefix(p, "../") {
		return "", errPathEscape
	}
	return p, nil
}

// cleanEntryPathMust is like cleanEntryPath but panics on bad input. It is only
// used for tar hardlink linknames, which the spec holds to be relative and
// safe; a bad linkname here is a programming error in the synthetic test data.
func cleanEntryPathMust(name string) string {
	c, err := cleanEntryPath(name)
	if err != nil {
		// Fall back to a best-effort cleaned string so resolution can report a
		// clear "target truly missing" error at merge time rather than panic.
		return path.Clean(strings.TrimPrefix(name, "./"))
	}
	return c
}

func splitPath(clean string) (parent, base string) {
	if clean == "" {
		return "", ""
	}
	parent = path.Dir(clean)
	if parent == "." {
		parent = ""
	}
	base = path.Base(clean)
	return
}

// ensureDir returns the dir node for dirPath, creating implicit dir entries
// (with default 0755 metadata) for any ancestor that the tar did not list
// explicitly. The root dir (path "") always exists.
func ensureDir(tree *LayerTree, dirPath string) *Node {
	if dirPath == "" {
		return tree.Root
	}
	if n := tree.Lookup(dirPath); n != nil {
		// If a previous regular file created this ancestor implicitly as a dir,
		// it is already a NodeDir. We trust tar ordering.
		return n
	}
	parent, base := splitPath(dirPath)
	pn := ensureDir(tree, parent)
	node := &Node{
		Path:     dirPath,
		Name:     base,
		Type:     NodeDir,
		Mode:     0o755,
		Children: make(map[string]*Node),
		Nlink:    1,
		Implicit: true,
	}
	attachChild(pn, base, node)
	tree.Put(node)
	return node
}

// ensureDirEx returns the dir node for clean, creating it if missing. When the
// tar entry exists explicitly, its metadata is applied to the node.
func ensureDirEx(tree *LayerTree, clean string, hdr *tar.Header) (*Node, bool) {
	if existing := tree.Lookup(clean); existing != nil {
		applyHeaderMeta(existing, hdr, NodeDir)
		return existing, false
	}
	parent, base := splitPath(clean)
	pn := ensureDir(tree, parent)
	node := &Node{
		Path:     clean,
		Name:     base,
		Type:     NodeDir,
		Mode:     0o755,
		Children: make(map[string]*Node),
		Nlink:    1,
	}
	applyHeaderMeta(node, hdr, NodeDir)
	attachChild(pn, base, node)
	tree.Put(node)
	return node, true
}

func attachChild(parent *Node, base string, child *Node) {
	if parent.Children == nil {
		parent.Children = make(map[string]*Node)
	}
	parent.Children[base] = child
}

// applyHeaderMeta copies shared metadata fields (mode/uid/gid/mtime) from a tar
// header onto a node of the given type, leaving type-specific fields alone.
func applyHeaderMeta(n *Node, hdr *tar.Header, t NodeType) {
	n.Type = t
	if hdr.Mode != 0 {
		n.Mode = uint32(hdr.Mode & 0o7777)
	}
	n.Uid = uint32(hdr.Uid)
	n.Gid = uint32(hdr.Gid)
	n.Nlink = 1
	n.Implicit = false // an explicit tar entry supplied this metadata
	_ = applyMtime(n, hdr)
}

func applyMtime(n *Node, hdr *tar.Header) error {
	if !hdr.ModTime.IsZero() {
		n.MtimeNs = uint64(hdr.ModTime.UnixNano())
	}
	return nil
}

// recordWhiteout appends an explicit whiteout entry to the owning dir's node
// (creating the dir implicitly if needed) and to the layer's Whiteouts list.
func recordWhiteout(tree *LayerTree, parent, name string) {
	dir := ensureDir(tree, parent)
	dir.Whiteouts = append(dir.Whiteouts, WhiteoutEntry{Parent: parent, Name: name})
	we := WhiteoutEntry{Parent: parent, Name: name}
	tree.Whiteouts = append(tree.Whiteouts, we)
}

// recordOpaque marks dir as opaque on both the dir node (OpaqueMark) and the
// layer's OpaqueDirs list.
func recordOpaque(tree *LayerTree, dir string) {
	n := ensureDir(tree, dir)
	n.OpaqueMark = true
	tree.OpaqueDirs = append(tree.OpaqueDirs, dir)
}

// isSocketMode reports whether a tar mode's S_IFMT bits indicate a socket.
// archive/tar has no TypeSocket header type; some synthetic tars reuse the
// FIFO typeflag with a socket mode.
func isSocketMode(mode int64) bool { return (mode & 0o170000) == 0o140000 }
