//go:build linux

package ingest

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"voila/internal/chunkstore"
)

// WalkOverlayUpper reads an overlayfs upperdir and produces a per-layer tree
// representing the layer diff (new/modified files, whiteouts, opaque dirs).
func WalkOverlayUpper(ctx context.Context, store chunkstore.ChunkStore, upperDir string) (*LayerWalkResult, error) {
	if store == nil {
		return nil, fmt.Errorf("ingest: nil chunk store")
	}
	upperDir, err := filepath.Abs(upperDir)
	if err != nil {
		return nil, err
	}
	tree := NewTree()
	res := &LayerWalkResult{Tree: tree}
	seen := make(map[chunkstore.ChunkID]bool)
	chunkBuf := make([]byte, ChunkSize)

	err = filepath.WalkDir(upperDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		rel, err := filepath.Rel(upperDir, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		rel = filepath.ToSlash(rel)

		// Whiteout char device: .wh.<name>
		if parentPath, wname, explicit, opaque := ClassifyEntry(rel); explicit || opaque {
			if opaque {
				recordOpaque(tree, parentPath)
				res.Tree.OpaqueN++
			} else {
				recordWhiteout(tree, parentPath, wname)
				res.Tree.WhiteoutsN++
			}
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		info, err := d.Info()
		if err != nil {
			return err
		}
		mode := info.Mode()

		// Overlay whiteout as char device 0:0
		if mode&fs.ModeCharDevice != 0 {
			sys, ok := info.Sys().(*syscall.Stat_t)
			if ok && sys.Rdev == 0 {
				if pp, wn, ex, _ := ClassifyEntry(rel); ex {
					recordWhiteout(tree, pp, wn)
					res.Tree.WhiteoutsN++
					return nil
				}
			}
		}

		// Opaque directory marker via xattr
		if d.IsDir() {
			if opaque, _ := isOverlayOpaque(p); opaque {
				recordOpaque(tree, rel)
				res.Tree.OpaqueN++
			}
		}

		if d.IsDir() {
			ensureDir(tree, rel)
			return nil
		}
		if !mode.IsRegular() {
			if mode&fs.ModeSymlink != 0 {
				target, err := os.Readlink(p)
				if err != nil {
					return err
				}
				parentPath, baseName := splitPath(rel)
				parentNode := ensureDir(tree, parentPath)
				node := &Node{
					Path:   rel,
					Name:   baseName,
					Type:   NodeSymlink,
					Target: target,
					Mode:   uint32(mode & 0o7777),
					Nlink:  1,
				}
				attachChild(parentNode, baseName, node)
				tree.Put(node)
			}
			return nil
		}

		parentPath, baseName := splitPath(rel)
		parentNode := ensureDir(tree, parentPath)
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		node := &Node{
			Path:    rel,
			Name:    baseName,
			Type:    NodeRegular,
			Mode:    uint32(mode & 0o7777),
			MtimeNs: uint64(info.ModTime().UnixNano()),
			Nlink:   1,
		}
		if err := chunkReader(ctx, f, store, seen, chunkBuf, node, res); err != nil {
			return err
		}
		attachChild(parentNode, baseName, node)
		tree.Put(node)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("ingest: walk overlay upper: %w", err)
	}
	return res, nil
}

func isOverlayOpaque(dir string) (bool, error) {
	buf := make([]byte, 1)
	n, err := syscall.Getxattr(dir, "trusted.overlay.opaque", buf)
	if err != nil {
		if err == syscall.ENODATA || err == syscall.ENOTSUP {
			return false, nil
		}
		return false, err
	}
	return n > 0 && buf[0] == 'y', nil
}
