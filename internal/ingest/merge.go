package ingest

import (
	"fmt"
	"sort"
)

// MergeTrees folds per-layer trees lower→upper into one merged tree, applying
// opaque whiteouts, explicit whiteouts and overlays exactly as the spec in
// tasks/03-ingest.md §Merge prescribes:
//
//   - Start with the lowest layer.
//   - For each upper layer: first apply opaque flags (drop ALL merged children
//     of that dir from lower layers, keep the dir itself), then explicit
//     whiteouts (drop the named child, whole subtree), then overlay entries:
//     upper replaces lower of the same path INCLUDING type changes (file over
//     dir drops the whole lower subtree; dir over file replaces it). Upper dir
//     over lower dir merges children with upper metadata winning.
//   - Resolve pending cross-layer hardlinks against the merged tree; error if
//     the target is not a regular file or is truly missing.
//
// The returned tree is a freshly-built one; the input layer trees are not
// mutated by MergeTrees (a later phase may resolve per-layer pending
// hardlinks against the merged tree by mutating them, after MergeTrees has
// already copied nodes into the merged tree).
func MergeTrees(layers []*LayerTree) (*LayerTree, error) {
	merged := NewTree()
	for _, layer := range layers {
		applyOpaque(merged, layer)
		applyWhiteouts(merged, layer)
		overlayLayer(merged, layer)
	}
	if err := resolvePending(merged); err != nil {
		return nil, err
	}
	return merged, nil
}

// applyOpaque drops all merged children of each dir marked opaque in this layer.
// The dir node itself is kept (it may be re-populated by the overlay step with
// this layer's own entries).
func applyOpaque(merged *LayerTree, layer *LayerTree) {
	dirs := append([]string(nil), layer.OpaqueDirs...)
	sort.Strings(dirs)
	for _, dirPath := range dirs {
		node := merged.byPath[dirPath]
		if node == nil || node.Type != NodeDir {
			continue
		}
		// Drop every existing child subtree; keep the dir shell.
		for _, name := range sortedNamesOf(node.Children) {
			child := node.Children[name]
			dropSubtreeByPath(merged, child)
			delete(node.Children, name)
		}
	}
}

// applyWhiteouts removes the named child subtree from the merged tree for each
// explicit whiteout in the layer. Missing parents are silently ignored.
func applyWhiteouts(merged *LayerTree, layer *LayerTree) {
	whiteouts := append([]WhiteoutEntry(nil), layer.Whiteouts...)
	sort.Slice(whiteouts, func(i, j int) bool {
		if whiteouts[i].Parent != whiteouts[j].Parent {
			return whiteouts[i].Parent < whiteouts[j].Parent
		}
		return whiteouts[i].Name < whiteouts[j].Name
	})
	for _, w := range whiteouts {
		var parent *Node
		if w.Parent == "" {
			parent = merged.Root
		} else {
			parent = merged.byPath[w.Parent]
		}
		if parent == nil || parent.Type != NodeDir {
			continue
		}
		child, ok := parent.Children[w.Name]
		if !ok {
			continue
		}
		dropSubtreeByPath(merged, child)
		delete(parent.Children, w.Name)
	}
}

// overlayLayer merges layer's entries onto merged, recursing structurally from
// the root so dir-over-dir merges children while other type changes replace.
// copies preserves within-layer hardlink sharing (a *Node appearing under two
// names maps to one merged node).
func overlayLayer(merged *LayerTree, layer *LayerTree) {
	copies := make(map[*Node]*Node)
	mergeDirInto(merged, merged.Root, layer.Root, copies)
}

// mergeDirInto merges srcDir's metadata and children into mergedDir (must be a
// dir in the merged tree). Upper metadata wins; children overlay per the rules.
func mergeDirInto(merged *LayerTree, mergedDir *Node, srcDir *Node, copies map[*Node]*Node) {
	// Upper metadata wins (only the common metadata fields; children merge).
	mergeMeta(mergedDir, srcDir)
	for _, name := range sortedNamesOf(srcDir.Children) {
		overlayChildInto(merged, mergedDir, name, srcDir.Children[name], copies)
	}
}

// overlayChildInto places src (a child from the upper layer) into mergedParent
// under name, applying the type-change rules.
func overlayChildInto(merged *LayerTree, mergedParent *Node, name string, src *Node, copies map[*Node]*Node) {
	// Hardlink reuse within a layer: the same *Node may appear under two names.
	// Record the alias path in byPath too, so AssignInodes sees both names and
	// emits the correct nlink in the merged manifest.
	if existing, ok := copies[src]; ok {
		mergedParent.Children[name] = existing
		aliasPath := name
		if mergedParent.Path != "" {
			aliasPath = mergedParent.Path + "/" + name
		}
		merged.byPath[aliasPath] = existing
		return
	}

	existing := mergedParent.Children[name]
	if existing != nil && existing.Type == NodeDir && src.Type == NodeDir {
		// Dir-over-dir: merge children, upper metadata wins.
		mergeDirInto(merged, existing, src, copies)
		return
	}

	// Replace (if any) and insert. Drop the existing subtree from byPath first.
	if existing != nil {
		dropSubtreeByPath(merged, existing)
		delete(mergedParent.Children, name)
	}

	m := copyShallow(src)
	copies[src] = m
	m.Name = name
	if mergedParent.Path == "" {
		m.Path = name
	} else {
		m.Path = mergedParent.Path + "/" + name
	}
	mergedParent.Children[name] = m
	merged.byPath[m.Path] = m

	if m.Type == NodeDir {
		// Fresh dir: src's children are all new (we just dropped the merged
		// subtree, so nothing exists under m yet). Overlay each child.
		m.Children = make(map[string]*Node)
		for _, cname := range sortedNamesOf(src.Children) {
			overlayChildInto(merged, m, cname, src.Children[cname], copies)
		}
	}
}

// resolvePending resolves cross-layer hardlink placeholders against the merged
// tree. A pending node at path Q with LinkTarget T becomes a second name for
// the regular file at T. If T is missing (or not a regular file) the error names
// both paths. Iterates to a fixpoint so dependencies between pending links resolve.
func resolvePending(merged *LayerTree) error {
	for {
		var pending []string
		for p, n := range merged.byPath {
			if n.Type == NodePendingHardlink {
				pending = append(pending, p)
			}
		}
		if len(pending) == 0 {
			return nil
		}
		sort.Strings(pending)
		progress := false
		for _, q := range pending {
			p := merged.byPath[q]
			target := merged.byPath[p.LinkTarget]
			if target == nil || target.Type != NodeRegular {
				continue
			}
			// Replace the pending node with the resolved target node.
			parentPath, base := splitPath(q)
			var parent *Node
			if parentPath == "" {
				parent = merged.Root
			} else {
				parent = merged.byPath[parentPath]
			}
			if parent == nil || parent.Type != NodeDir {
				return fmt.Errorf("ingest: cannot resolve hardlink %q -> %q: parent %q missing",
					q, p.LinkTarget, parentPath)
			}
			parent.Children[base] = target
			// Re-key byPath so the resolved name and the target share one node,
			// which AssignInodes counts as nlink=2.
			merged.byPath[q] = target
			progress = true
		}
		if !progress {
			q := pending[0]
			p := merged.byPath[q]
			t := p.LinkTarget
			if existing, ok := merged.byPath[t]; ok && existing.Type != NodeRegular {
				return fmt.Errorf("ingest: hardlink %q -> %q: target is not a regular file (type %d)",
					q, t, existing.Type)
			}
			return fmt.Errorf("ingest: hardlink %q -> %q: target truly missing", q, t)
		}
	}
}

// -----------------------------------------------------------------------------
// helpers shared by merge.go (kept local to keep the algorithm readable)
// -----------------------------------------------------------------------------

func sortedNamesOf(children map[string]*Node) []string {
	names := make([]string, 0, len(children))
	for n := range children {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// mergeMeta copies upper-dir metadata onto a dir node, preserving its children
// (which will be merged/overlaid separately). Implicit upper dirs (fabricated
// by ensureDir with placeholder 0755 root:root) never override the lower
// layer's real metadata.
func mergeMeta(dst, upper *Node) {
	if upper.Implicit {
		return
	}
	if upper.Mode != 0 {
		dst.Mode = upper.Mode
	}
	dst.Uid = upper.Uid
	dst.Gid = upper.Gid
	if upper.MtimeNs != 0 {
		dst.MtimeNs = upper.MtimeNs
	}
}

// copyShallow returns a shallow copy of n with fresh per-node maps; Children is
// left nil for callers to populate.
func copyShallow(n *Node) *Node {
	m := &Node{}
	*m = *n
	m.Children = nil
	if len(n.Xattrs) > 0 {
		m.Xattrs = make(map[string][]byte, len(n.Xattrs))
		for k, v := range n.Xattrs {
			m.Xattrs[k] = v
		}
	}
	return m
}

// dropSubtreeByPath removes node and all its descendants from merged.byPath.
// It does not unlink from the parent's Children map (the caller does that).
func dropSubtreeByPath(merged *LayerTree, node *Node) {
	if node == nil {
		return
	}
	if node.Type == NodeDir {
		for _, name := range sortedNamesOf(node.Children) {
			dropSubtreeByPath(merged, node.Children[name])
		}
	}
	if merged.byPath != nil {
		delete(merged.byPath, node.Path)
	}
}
