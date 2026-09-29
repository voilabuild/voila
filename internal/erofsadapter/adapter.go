// Package erofsadapter builds an EROFS metadata blob from a merged voila
// manifest tree, using github.com/erofs/go-erofs in MetadataOnly mode.
//
// The blob is a pure function of the tree (deterministic): same tree → same
// bytes. It is built at mount time today; caching as a local chunk is planned
// but not implemented yet — each cold mount rebuilds from the tree.
//
// The virtual device layout is:
//
//	[metadata region: the EROFS blob][data region: 1 MiB slots, one per unique chunk]
//
// The EROFS chunk indexes point at 1 MiB slots in the data region. The NBD
// server translates device offsets → slot → chunk → store.Get. Holes use
// EROFS_NULL_ADDR natively (no slot, no fetch — the kernel serves zeros).
//
// go-erofs builds chunk indexes with DeviceID=1 (an extra device). We
// post-process the image to patch DeviceID to 0 (the primary device) so a
// single NBD device serves both metadata and data. See patch.go.
package erofsadapter

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/erofs/go-erofs"

	"voila/internal/chunkstore"
	"voila/internal/mount"
)

// ChunkSize is the size of each slot in the data region. It matches voila's
// 1 MiB chunk size so File.blocks map 1:1 onto EROFS chunk indexes.
const ChunkSize = 1 << 20

// BuildResult is the output of Build: the EROFS metadata blob and the
// supporting tables the NBD server needs.
type BuildResult struct {
	// Metadata is the patched EROFS image (superblock + inodes + dirents +
	// xattrs + chunk indexes, with DeviceID=0). The NBD server pins this in
	// RAM and serves metadata blocks from it.
	Metadata []byte

	// SlotTable maps each 1 MiB slot index to its voila chunk ID. The NBD
	// server uses this to translate data-region offsets → chunk fetches.
	SlotTable []chunkstore.ChunkID

	// DeviceSize is the total size of the virtual NBD device (metadata +
	// data region). This is what Backend.Size() returns.
	DeviceSize int64

	// DataOffset is the byte offset where the data region starts. The NBD
	// server uses this to distinguish metadata requests from data requests.
	DataOffset int64

	// FileSlots maps each file inode to its ordered slot indices, for
	// file-aware prefetch in the NBD server.
	FileSlots map[uint64][]uint64
}

// Build constructs an EROFS metadata blob from a merged voila manifest tree.
// The blob is deterministic (same tree → same bytes). The data region of the
// virtual device is a flat array of 1 MiB slots, one per unique chunk; chunk
// indexes point at slot boundaries.
func Build(ctx context.Context, tree *mount.Tree) (*BuildResult, error) {
	if tree == nil {
		return nil, fmt.Errorf("erofsadapter: nil tree")
	}

	// 1. Fetch all external subtree manifests in parallel. The walk below
	// visits every directory; loading subtrees lazily during it would pay
	// one network round trip per manifest, serialized (measured: ~23s of a
	// 25s python:3.12 cold start over a ~52ms-RTT registry). Best-effort:
	// subtrees that fail here are retried (and surface errors) on demand.
	tree.PrefetchManifests(ctx, 32)

	// 2. Walk the tree: collect entries, assign slots, build the slot table.
	walk := walkTree(ctx, tree)

	// 3. Build the EROFS image via go-erofs.
	var sb seekBuffer
	// go-erofs has no WithChunkBits option; non-contiguous files default to
	// chunkBits=0 (4 KiB). patchToDevice0 collapses those to 1 MiB so each
	// index matches one voila slot. See patch.go.
	w := erofs.Create(&sb, erofs.WithBlockSize(4096))
	src := &voilaFS{
		tree:    tree,
		ctx:     ctx,
		entries: walk.entries,
		paths:   walk.paths,
		slotMap: walk.slotMap,
	}
	if err := w.CopyFrom(src, erofs.MetadataOnly()); err != nil {
		return nil, fmt.Errorf("erofsadapter: CopyFrom: %w", err)
	}

	// 4. Post-process metadata: set uid/gid/mode/mtime/xattrs/nlink that
	// CopyFrom couldn't set (builder.Entry is internal to go-erofs).
	if err := applyMetadata(w, walk); err != nil {
		return nil, fmt.Errorf("erofsadapter: applyMetadata: %w", err)
	}

	// 5. Serialize the image.
	if err := w.Close(); err != nil {
		return nil, fmt.Errorf("erofsadapter: Close: %w", err)
	}
	image := sb.Bytes()

	// 6. Patch DeviceID from 1 to 0 so a single NBD device serves both
	// metadata and data.
	patched, err := patchToDevice0(image, walk)
	if err != nil {
		return nil, fmt.Errorf("erofsadapter: patch: %w", err)
	}

	// 7. Compute device layout.
	dataOffset := int64(len(patched))
	// Round up to block boundary.
	blkSize := int64(4096)
	if rem := dataOffset % blkSize; rem != 0 {
		dataOffset += blkSize - rem
	}
	// Pad metadata to dataOffset.
	if dataOffset > int64(len(patched)) {
		pad := make([]byte, dataOffset-int64(len(patched)))
		patched = append(patched, pad...)
	}
	deviceSize := dataOffset + int64(len(walk.slotList))*ChunkSize

	return &BuildResult{
		Metadata:   patched,
		SlotTable:  walk.slotList,
		DeviceSize: deviceSize,
		DataOffset: dataOffset,
		FileSlots:  walk.fileSlots,
	}, nil
}

// ----- tree walk -----

type walkResult struct {
	entries   map[string]*mount.NodeInfo    // path → node info
	paths     []string                      // sorted paths for deterministic iteration
	slotMap   map[chunkstore.ChunkID]uint64 // chunk → slot index
	slotList  []chunkstore.ChunkID          // slot → chunk ID
	fileSlots map[uint64][]uint64           // file inode → slot indices
}

func walkTree(ctx context.Context, tree *mount.Tree) *walkResult {
	w := &walkResult{
		entries:   make(map[string]*mount.NodeInfo),
		slotMap:   make(map[chunkstore.ChunkID]uint64),
		fileSlots: make(map[uint64][]uint64),
	}
	// Add the root dir itself.
	if rootInfo, err := tree.Get(ctx, tree.Root()); err == nil {
		w.entries["/"] = rootInfo
	}
	walkDir(ctx, tree, tree.Root(), "/", w)
	sort.Strings(w.paths)
	return w
}

func walkDir(ctx context.Context, tree *mount.Tree, dirInode uint64, dirPath string, w *walkResult) {
	entries, err := tree.ReadDir(ctx, dirInode)
	if err != nil {
		return
	}
	for _, e := range entries {
		childPath := path.Join(dirPath, e.Name)
		info, err := tree.Get(ctx, e.Inode)
		if err != nil {
			continue
		}
		w.entries[childPath] = info
		w.paths = append(w.paths, childPath)

		if info.Kind == mount.KindFile && info.File != nil {
			for _, b := range info.File.Blocks {
				if len(b.ChunkId) == 0 {
					continue // hole
				}
				var cid chunkstore.ChunkID
				copy(cid[:], b.ChunkId)
				if _, ok := w.slotMap[cid]; !ok {
					w.slotMap[cid] = uint64(len(w.slotList))
					w.slotList = append(w.slotList, cid)
				}
				w.fileSlots[info.Inode] = append(w.fileSlots[info.Inode], w.slotMap[cid])
			}
		}

		if e.Kind == mount.KindDir {
			walkDir(ctx, tree, e.Inode, childPath, w)
		}
	}
}

// ----- fs.FS adapter -----

// voilaFS presents a voila mount.Tree as an fs.FS for go-erofs's CopyFrom.
// It implements deviceBlocker (DeviceBlocks) and readLinker (ReadLink).
type voilaFS struct {
	tree    *mount.Tree
	ctx     context.Context
	entries map[string]*mount.NodeInfo
	paths   []string
	slotMap map[chunkstore.ChunkID]uint64
}

func (dfs *voilaFS) Open(name string) (fs.File, error) {
	if name == "." {
		name = "/"
	}
	name = cleanPath(name)
	info, ok := dfs.entries[name]
	if !ok {
		return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrNotExist}
	}
	if info.Kind == mount.KindDir {
		return &voilaDir{owner: dfs, path: name, info: info}, nil
	}
	return &voilaFile{info: info, path: name}, nil
}

func (dfs *voilaFS) ReadLink(name string) (string, error) {
	name = cleanPath(name)
	info, ok := dfs.entries[name]
	if !ok || info.Kind != mount.KindSymlink || info.Symlink == nil {
		return "", &fs.PathError{Op: "readlink", Path: name, Err: fs.ErrNotExist}
	}
	return info.Symlink.Target, nil
}

func (dfs *voilaFS) DeviceBlocks() uint64 {
	return uint64(len(dfs.slotMap)) * (ChunkSize / 4096)
}

// voilaDir implements fs.ReadDirFile for a directory in the voila tree.
type voilaDir struct {
	owner *voilaFS
	path  string
	info  *mount.NodeInfo
	did   bool
}

func (d *voilaDir) Stat() (fs.FileInfo, error) {
	return newDirInfo(d.path, d.info), nil
}

func (d *voilaDir) Read([]byte) (int, error) {
	return 0, &fs.PathError{Op: "read", Path: d.path, Err: fmt.Errorf("is a directory")}
}

func (d *voilaDir) Close() error { return nil }

func (d *voilaDir) ReadDir(n int) ([]fs.DirEntry, error) {
	if d.did {
		return nil, io.EOF
	}
	d.did = true
	entries, err := d.owner.tree.ReadDir(d.owner.ctx, d.info.Inode)
	if err != nil {
		return nil, err
	}
	out := make([]fs.DirEntry, 0, len(entries))
	for _, e := range entries {
		childPath := path.Join(d.path, e.Name)
		info, ok := d.owner.entries[childPath]
		if !ok {
			continue
		}
		out = append(out, &voilaDirEntry{name: e.Name, info: info, path: childPath, slotMap: d.owner.slotMap})
	}
	return out, nil
}

// voilaFile is a stub fs.File for non-directory entries. In MetadataOnly mode,
// CopyFrom never opens files — it uses DataRange() from the FileInfo instead.
type voilaFile struct {
	info *mount.NodeInfo
	path string
}

func (f *voilaFile) Stat() (fs.FileInfo, error) {
	return newFileInfo(f.path, f.info, nil), nil
}

func (f *voilaFile) Read([]byte) (int, error) {
	return 0, io.EOF
}

func (f *voilaFile) Close() error { return nil }

// voilaDirEntry implements fs.DirEntry.
type voilaDirEntry struct {
	name    string
	info    *mount.NodeInfo
	path    string
	slotMap map[chunkstore.ChunkID]uint64
}

func (e *voilaDirEntry) Name() string { return e.name }
func (e *voilaDirEntry) IsDir() bool  { return e.info.Kind == mount.KindDir }
func (e *voilaDirEntry) Type() fs.FileMode {
	return modeFromFileInfo(e.info).Type()
}
func (e *voilaDirEntry) Info() (fs.FileInfo, error) {
	return newFileInfo(e.path, e.info, e.slotMap), nil
}

// ----- FileInfo -----

func newDirInfo(path string, info *mount.NodeInfo) fs.FileInfo {
	return &voilaFileInfo{path: path, info: info, isDir: true}
}

func newFileInfo(path string, info *mount.NodeInfo, slotMap map[chunkstore.ChunkID]uint64) fs.FileInfo {
	return &voilaFileInfo{path: path, info: info, slotMap: slotMap}
}

type voilaFileInfo struct {
	path    string
	info    *mount.NodeInfo
	isDir   bool
	slotMap map[chunkstore.ChunkID]uint64
}

func (fi *voilaFileInfo) Name() string { return path.Base(fi.path) }
func (fi *voilaFileInfo) Size() int64 {
	if fi.info.File != nil {
		return int64(fi.info.File.Size)
	}
	if fi.info.Symlink != nil {
		return int64(len(fi.info.Symlink.Target))
	}
	return 0
}
func (fi *voilaFileInfo) Mode() fs.FileMode { return modeFromFileInfo(fi.info) }
func (fi *voilaFileInfo) ModTime() time.Time {
	var ns uint64
	if fi.info.File != nil {
		ns = fi.info.File.MtimeNs
	} else if fi.info.Dir != nil {
		ns = fi.info.Dir.MtimeNs
	}
	if ns == 0 {
		return time.Unix(0, 0)
	}
	return time.Unix(0, int64(ns))
}
func (fi *voilaFileInfo) IsDir() bool { return fi.info.Kind == mount.KindDir }
func (fi *voilaFileInfo) Sys() any    { return nil }

// DataRange implements the dataRanger interface that go-erofs's CopyFrom
// uses to build chunk indexes in MetadataOnly mode.
//
// Consecutive blocks whose slots are adjacent in the virtual device are
// merged into a single DataRange. This makes go-erofs treat the file as
// "contiguous" (one range), which sets chunkBits = minChunkBits(size) —
// a larger chunk size that produces far fewer chunk index entries. The
// slots ARE contiguous in the virtual device (the data region is a flat
// array of 1 MiB slots), so the merge is semantically correct: the kernel
// reads a contiguous region and the NBD backend translates each 1 MiB
// offset to the correct slot/chunk.
func (fi *voilaFileInfo) DataRange() []erofs.DataRange {
	if fi.info.File == nil {
		return nil
	}
	f := fi.info.File
	var ranges []erofs.DataRange
	var pos uint64
	// mergeIdx is the index in ranges of the current mergeable data range
	// (-1 = none). When the next block is contiguous (file offset and slot
	// both consecutive), we extend ranges[mergeIdx].Size instead of
	// emitting a new range.
	mergeIdx := -1
	for _, b := range f.Blocks {
		blkStart := b.OffsetInFile
		if blkStart > pos {
			// Gap = hole.
			mergeIdx = -1
			ranges = append(ranges, erofs.DataRange{
				Offset: -1, // holeOffset
				Size:   int64(blkStart - pos),
			})
			pos = blkStart
		}
		blkLen := b.LogicalLen
		if blkLen == 0 {
			blkLen = ChunkSize
		}
		if len(b.ChunkId) == 0 {
			// Explicit hole block.
			mergeIdx = -1
			ranges = append(ranges, erofs.DataRange{Offset: -1, Size: int64(b.LogicalLen)})
		} else {
			var cid chunkstore.ChunkID
			copy(cid[:], b.ChunkId)
			slot, ok := fi.slotMap[cid]
			if !ok {
				// Should not happen; treat as hole.
				mergeIdx = -1
				ranges = append(ranges, erofs.DataRange{Offset: -1, Size: int64(b.LogicalLen)})
			} else {
				devOff := int64(slot) * ChunkSize
				if mergeIdx >= 0 &&
					pos == blkStart &&
					ranges[mergeIdx].Offset+ranges[mergeIdx].Size == devOff {
					// Extend the current merged range.
					ranges[mergeIdx].Size += int64(b.LogicalLen)
				} else {
					ranges = append(ranges, erofs.DataRange{
						Device: 0,
						Offset: devOff,
						Size:   int64(b.LogicalLen),
					})
					mergeIdx = len(ranges) - 1
				}
			}
		}
		pos = blkStart + b.LogicalLen
	}
	// Trailing hole.
	if pos < f.Size {
		ranges = append(ranges, erofs.DataRange{Offset: -1, Size: int64(f.Size - pos)})
	}
	return ranges
}

// ----- metadata post-processing -----

func applyMetadata(w *erofs.Writer, walk *walkResult) error {
	for _, p := range walk.paths {
		info := walk.entries[p]
		var mode uint32
		var uid, gid uint32
		var mtimeNs uint64
		var nlink uint32
		var xattrs map[string][]byte

		switch info.Kind {
		case mount.KindDir:
			d := info.Dir
			mode = d.Mode | 0o040000 // S_IFDIR
			uid = d.Uid
			gid = d.Gid
			mtimeNs = d.MtimeNs
			nlink = 2 // directories have at least . and ..
		case mount.KindFile:
			f := info.File
			mode = f.Mode | 0o100000 // S_IFREG
			uid = f.Uid
			gid = f.Gid
			mtimeNs = f.MtimeNs
			if f.Nlink > 0 {
				nlink = f.Nlink
			}
			if len(f.Xattrs) > 0 {
				xattrs = f.Xattrs
			}
		case mount.KindSymlink:
			s := info.Symlink
			mode = 0o120777 // S_IFLNK | 0o777
			uid = s.Uid
			gid = s.Gid
		case mount.KindDevice:
			dv := info.Device
			if dv.IsChar {
				mode = dv.Mode | 0o020000 // S_IFCHR
			} else {
				mode = dv.Mode | 0o060000 // S_IFBLK
			}
			uid = dv.Uid
			gid = dv.Gid
		}

		// Set permissions (mode permission bits only; type bits come from
		// CopyFrom which read them from FileInfo.Mode()).
		if err := w.Chmod(p, fs.FileMode(mode&0o7777)); err != nil {
			return fmt.Errorf("chmod %s: %w", p, err)
		}
		if err := w.Chown(p, int(uid), int(gid)); err != nil {
			return fmt.Errorf("chown %s: %w", p, err)
		}
		if mtimeNs > 0 {
			t := time.Unix(0, int64(mtimeNs))
			if err := w.Chtimes(p, t, t); err != nil {
				return fmt.Errorf("chtimes %s: %w", p, err)
			}
		}
		if nlink > 1 {
			if err := w.SetNlink(p, nlink); err != nil {
				return fmt.Errorf("setnlink %s: %w", p, err)
			}
		}
		for k, v := range xattrs {
			if err := w.Setxattr(p, k, string(v)); err != nil {
				return fmt.Errorf("setxattr %s %s: %w", p, k, err)
			}
		}
	}
	return nil
}

// ----- helpers -----

func cleanPath(p string) string {
	if p == "" || p == "." {
		return "/"
	}
	p = path.Clean(p)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

func modeFromFileInfo(info *mount.NodeInfo) fs.FileMode {
	switch info.Kind {
	case mount.KindDir:
		return fs.ModeDir | fs.FileMode(info.Dir.GetMode()&0o7777)
	case mount.KindFile:
		return fs.FileMode(info.File.GetMode() & 0o7777)
	case mount.KindSymlink:
		return fs.ModeSymlink | 0o777
	case mount.KindDevice:
		if info.Device.GetIsChar() {
			return fs.ModeDevice | fs.ModeCharDevice | fs.FileMode(info.Device.GetMode()&0o7777)
		}
		return fs.ModeDevice | fs.FileMode(info.Device.GetMode()&0o7777)
	default:
		return 0
	}
}

// seekBuffer implements io.WriteSeeker over a byte slice, supporting
// overwrite-after-seek (go-erofs writes data first, then seeks back to
// write the real superblock over the placeholder).
//
// Growth is exponential. go-erofs emits thousands of tiny dirent/chunk
// writes; allocating exactly `pos+n` and copying on every Write is O(n²)
// and dominated python:3.13's 2s Close().
type seekBuffer struct {
	buf []byte
	pos int
	end int // high-water mark; Bytes() returns buf[:end]
}

func (s *seekBuffer) Write(p []byte) (int, error) {
	end := s.pos + len(p)
	if end > cap(s.buf) {
		ncap := cap(s.buf) * 2
		if ncap < end {
			ncap = end
		}
		if ncap < 4096 {
			ncap = 4096
		}
		grow := make([]byte, ncap)
		copy(grow, s.buf[:s.end])
		s.buf = grow
	}
	copy(s.buf[s.pos:], p)
	s.pos = end
	if end > s.end {
		s.end = end
	}
	return len(p), nil
}

func (s *seekBuffer) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		s.pos = int(offset)
	case io.SeekCurrent:
		s.pos += int(offset)
	case io.SeekEnd:
		s.pos = s.end + int(offset)
	}
	return int64(s.pos), nil
}

func (s *seekBuffer) Bytes() []byte { return s.buf[:s.end] }

// Ensure voilaFS satisfies the interfaces go-erofs's CopyFrom checks.
var _ interface {
	fs.FS
} = (*voilaFS)(nil)
