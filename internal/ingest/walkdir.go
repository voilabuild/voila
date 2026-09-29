package ingest

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"

	"voila/internal/chunkstore"
)

// WalkDirOptions configures WalkDir.
type WalkDirOptions struct {
	// ContextDir is the build context root on disk.
	ContextDir string
	// Sources are paths relative to ContextDir (or absolute within it).
	Sources []string
	// Dest is the destination directory inside the image rootfs.
	Dest string
	// Ignore, when non-nil, returns true for context-relative paths that
	// should be skipped (.dockerignore).
	Ignore func(rel string) bool
}

// WalkDir ingests files from a build context into a new per-layer tree,
// placing them under opts.Dest. It mirrors WalkLayer's chunking but reads
// from the local filesystem instead of a tar stream.
func WalkDir(ctx context.Context, store chunkstore.ChunkStore, opts WalkDirOptions) (*LayerWalkResult, error) {
	if store == nil {
		return nil, fmt.Errorf("ingest: nil chunk store")
	}
	contextDir, err := filepath.Abs(opts.ContextDir)
	if err != nil {
		return nil, err
	}
	if opts.Dest == "" {
		return nil, fmt.Errorf("ingest: COPY destination must be non-empty")
	}
	dest := cleanImagePath(opts.Dest)
	tree := NewTree()
	res := &LayerWalkResult{Tree: tree}
	seen := make(map[chunkstore.ChunkID]bool)
	chunkBuf := make([]byte, ChunkSize)

	// Ensure destination directory exists in the layer.
	if dest != "" {
		ensureDir(tree, dest)
	}

	for _, src := range opts.Sources {
		abs, rel, err := resolveContextPath(contextDir, src)
		if err != nil {
			return nil, err
		}
		if opts.Ignore != nil && opts.Ignore(rel) {
			continue
		}
		info, err := os.Stat(abs)
		if err != nil {
			return nil, fmt.Errorf("ingest: stat %q: %w", src, err)
		}
		if info.IsDir() {
			if err := walkContextDir(ctx, abs, rel, contextDir, dest, tree, store, seen, chunkBuf, opts.Ignore, res); err != nil {
				return nil, err
			}
			continue
		}
		target := path.Join(dest, path.Base(rel))
		if err := ingestContextFile(ctx, abs, target, tree, store, seen, chunkBuf, res); err != nil {
			return nil, err
		}
	}
	return res, nil
}

func walkContextDir(
	ctx context.Context,
	absDir, relDir, contextDir, dest string,
	tree *LayerTree,
	store chunkstore.ChunkStore,
	seen map[chunkstore.ChunkID]bool,
	chunkBuf []byte,
	ignore func(string) bool,
	res *LayerWalkResult,
) error {
	return filepath.WalkDir(absDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		rel, err := filepath.Rel(contextDir, p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if ignore != nil && ignore(rel) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			targetDir := path.Join(dest, rel)
			ensureDir(tree, targetDir)
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		target := path.Join(dest, rel)
		return ingestContextFile(ctx, p, target, tree, store, seen, chunkBuf, res)
	})
}

func ingestContextFile(
	ctx context.Context,
	abs, target string,
	tree *LayerTree,
	store chunkstore.ChunkStore,
	seen map[chunkstore.ChunkID]bool,
	chunkBuf []byte,
	res *LayerWalkResult,
) error {
	target = cleanImagePath(target)
	info, err := os.Stat(abs)
	if err != nil {
		return err
	}
	parentPath, base := splitPath(target)
	parent := ensureDir(tree, parentPath)
	f, err := os.Open(abs)
	if err != nil {
		return err
	}
	defer f.Close()
	node := &Node{
		Path:    target,
		Name:    base,
		Type:    NodeRegular,
		Mode:    uint32(info.Mode() & 0o7777),
		Uid:     0,
		Gid:     0,
		MtimeNs: uint64(info.ModTime().UnixNano()),
		Nlink:   1,
	}
	if err := chunkReader(ctx, f, store, seen, chunkBuf, node, res); err != nil {
		return err
	}
	attachChild(parent, base, node)
	tree.Put(node)
	return nil
}

func chunkReader(
	ctx context.Context,
	r io.Reader,
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
		n, err := io.ReadFull(r, chunkBuf)
		if n > 0 {
			buf := chunkBuf[:n]
			res.BytesIn += uint64(n)
			node.Size += uint64(n)
			block, isNew, storedAdd, err := putChunk(store, seen, buf)
			if err != nil {
				return err
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
			if err == io.ErrUnexpectedEOF && n == 0 {
				return fmt.Errorf("ingest: short read mid-chunk")
			}
			break
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func resolveContextPath(contextDir, src string) (abs, rel string, err error) {
	if strings.HasPrefix(src, "/") {
		return "", "", fmt.Errorf("ingest: absolute COPY source %q not allowed", src)
	}
	abs = filepath.Join(contextDir, filepath.FromSlash(src))
	abs, err = filepath.Abs(abs)
	if err != nil {
		return "", "", err
	}
	contextDir, err = filepath.Abs(contextDir)
	if err != nil {
		return "", "", err
	}
	if !strings.HasPrefix(abs, contextDir+string(os.PathSeparator)) && abs != contextDir {
		return "", "", fmt.Errorf("ingest: path %q escapes build context", src)
	}
	rel, err = filepath.Rel(contextDir, abs)
	if err != nil {
		return "", "", err
	}
	return abs, filepath.ToSlash(rel), nil
}

func cleanImagePath(p string) string {
	p = strings.TrimPrefix(p, "./")
	p = path.Clean(p)
	if p == "." {
		return ""
	}
	if strings.HasPrefix(p, "/") {
		p = strings.TrimPrefix(p, "/")
	}
	if p == ".." || strings.HasPrefix(p, "../") {
		return ""
	}
	return p
}
