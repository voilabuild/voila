//go:build linux

package mount

import (
	"context"
	"errors"
	"io"
	"log"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"

	"voila/internal/chunkstore"
)

// fuseNode is the fs.InodeEmbedder implementation backed by a (Tree, NodeInfo,
// store) triple. One fuseNode backs one manifest inode; the embedded fs.Inode
// is created lazily by fs.Mount / Lookup.
type fuseNode struct {
	fs.Inode

	tree  *Tree
	store chunkstore.ChunkStore

	// inode is the manifest inode this node represents.
	inode uint64
	// info is the resolved manifest entry. It is immutable.
	info *NodeInfo
}

// Compile-time interface checks for all the Node* ops we implement.
var (
	_ inodeEmbedder      = (*fuseNode)(nil)
	_ fs.NodeLookuper    = (*fuseNode)(nil)
	_ fs.NodeGetattrer   = (*fuseNode)(nil)
	_ fs.NodeReaddirer   = (*fuseNode)(nil)
	_ fs.NodeOpener      = (*fuseNode)(nil)
	_ fs.NodeReader      = (*fuseNode)(nil)
	_ fs.NodeReadlinker  = (*fuseNode)(nil)
	_ fs.NodeGetxattrer  = (*fuseNode)(nil)
	_ fs.NodeListxattrer = (*fuseNode)(nil)
	_ fs.NodeStatfser    = (*fuseNode)(nil)
	_ fs.NodeAccesser    = (*fuseNode)(nil)
)

// inodeEmbedder aliases fs.InodeEmbedder so the interface assertion above names
// an exported symbol (the struct embeds fs.Inode which provides the
// unexported methods required by the interface).
type inodeEmbedder = fs.InodeEmbedder

var _ inodeEmbedder = (*fuseNode)(nil)

// resolveInode returns the NodeInfo for the given inode, loading external
// subtrees on demand.
func (n *fuseNode) resolveInode(ctx context.Context, inode uint64) (*NodeInfo, error) {
	return n.tree.Get(ctx, inode)
}

// typeBits returns the S_IFMT mode bits for n's kind.
func (n *fuseNode) typeBits() uint32 {
	switch n.info.Kind {
	case KindDir:
		return syscall.S_IFDIR
	case KindFile:
		return syscall.S_IFREG
	case KindSymlink:
		return syscall.S_IFLNK
	case KindDevice:
		if n.info.Device != nil && n.info.Device.GetIsChar() {
			return syscall.S_IFCHR
		}
		return syscall.S_IFBLK
	default:
		return syscall.S_IFREG
	}
}

// mkdev encodes major/minor into Linux's 32-bit dev_t layout. The legacy
// 16-bit (major<<8 | minor) encoding truncates minors >= 256.
func mkdev(major, minor uint32) uint32 {
	return (minor & 0xff) | (major << 8) | ((minor &^ 0xff) << 12)
}

// fillAttrFromInfo populates a fuse.Attr from the manifest metadata. It is the
// single source of truth for attributes — used by both Getattr and Lookup so
// the kernel never caches divergent views (attr/entry timeouts are 1h).
func fillAttrFromInfo(info *NodeInfo, out *fuse.Attr) {
	out.Ino = info.Inode
	out.Nlink = 1
	out.Blksize = 4096
	switch info.Kind {
	case KindDir:
		d := info.Dir
		out.Mode = syscall.S_IFDIR | (d.GetMode() & 0o7777)
		out.Uid = d.GetUid()
		out.Gid = d.GetGid()
		out.Mtime = d.GetMtimeNs() / 1e9
		out.Mtimensec = uint32(d.GetMtimeNs() % 1e9)
		out.Size = 0
		out.Blocks = 1
	case KindFile:
		f := info.File
		out.Mode = syscall.S_IFREG | (f.GetMode() & 0o7777)
		out.Uid = f.GetUid()
		out.Gid = f.GetGid()
		out.Mtime = f.GetMtimeNs() / 1e9
		out.Mtimensec = uint32(f.GetMtimeNs() % 1e9)
		out.Size = f.GetSize()
		// st_blocks is in 512-byte units.
		out.Blocks = (f.GetSize() + 511) / 512
		if nl := f.GetNlink(); nl > 0 {
			out.Nlink = nl
		}
	case KindSymlink:
		s := info.Symlink
		out.Mode = syscall.S_IFLNK | 0o777
		out.Uid = s.GetUid()
		out.Gid = s.GetGid()
		out.Size = uint64(len(s.GetTarget()))
		out.Blocks = (out.Size + 511) / 512
	case KindDevice:
		d := info.Device
		if d.GetIsChar() {
			out.Mode = syscall.S_IFCHR | (d.GetMode() & 0o7777)
		} else {
			out.Mode = syscall.S_IFBLK | (d.GetMode() & 0o7777)
		}
		out.Uid = d.GetUid()
		out.Gid = d.GetGid()
		out.Rdev = mkdev(d.GetRdevMajor(), d.GetRdevMinor())
		out.Size = 0
		out.Blocks = 0
	}
	// Atime/Ctime default to Mtime when the manifest does not carry them.
	out.Atime = out.Mtime
	out.Atimensec = out.Mtimensec
	out.Ctime = out.Mtime
	out.Ctimensec = out.Mtimensec
}

// newChild constructs a fuseNode for the manifest inode resolved by info. The
// returned *fs.Inode is wired into the kernel-visible tree via NewInode.
func (n *fuseNode) newChild(ctx context.Context, info *NodeInfo) *fs.Inode {
	child := &fuseNode{
		tree:  n.tree,
		store: n.store,
		inode: info.Inode,
		info:  info,
	}
	mode := child.typeBits()
	return n.NewInode(ctx, child, fs.StableAttr{Ino: info.Inode, Mode: mode})
}

// Lookup implements fs.NodeLookuper.
func (n *fuseNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if n.info.Kind != KindDir {
		return nil, syscall.ENOTDIR
	}
	info, err := n.tree.Lookup(ctx, n.inode, name)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, syscall.ENOENT
		}
		log.Printf("voilad fuse: lookup inode=%d name=%q: %v", n.inode, name, err)
		return nil, syscall.EIO
	}
	ch := n.newChild(ctx, info)
	fillFromInfo(out, info)
	out.SetAttrTimeout(time.Hour)
	out.SetEntryTimeout(time.Hour)
	return ch, 0
}

// fillFromInfo writes attribute data from info into an EntryOut.
func fillFromInfo(out *fuse.EntryOut, info *NodeInfo) {
	fillAttrFromInfo(info, &out.Attr)
}

// Getattr implements fs.NodeGetattrer.
func (n *fuseNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	fillAttrFromInfo(n.info, &out.Attr)
	out.SetTimeout(time.Hour)
	return 0
}

// Readdir implements fs.NodeReaddirer.
func (n *fuseNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	if n.info.Kind != KindDir {
		return nil, syscall.ENOTDIR
	}
	entries, err := n.tree.ReadDir(ctx, n.inode)
	if err != nil {
		log.Printf("voilad fuse: readdir inode=%d: %v", n.inode, err)
		return nil, syscall.EIO
	}
	out := make([]fuse.DirEntry, 0, len(entries))
	for _, e := range entries {
		out = append(out, fuse.DirEntry{
			Name: e.Name,
			Ino:  e.Inode,
			Mode: kindToModeBits(e.Kind),
		})
	}
	return fs.NewListDirStream(out), 0
}

func kindToModeBits(k NodeKind) uint32 {
	switch k {
	case KindDir:
		return syscall.S_IFDIR
	case KindFile:
		return syscall.S_IFREG
	case KindSymlink:
		return syscall.S_IFLNK
	case KindDevice:
		return syscall.S_IFBLK
	default:
		return syscall.S_IFREG
	}
}

// fileHandle carries a per-open FileReader whose single-chunk cache absorbs
// the kernel's sub-chunk read windows (see FileReader).
type fileHandle struct {
	r *FileReader
}

// Open implements fs.NodeOpener. It rejects any access that would write, with
// EROFS (the mount is read-only — plan §6).
func (n *fuseNode) Open(ctx context.Context, flags uint32) (fs.FileHandle, uint32, syscall.Errno) {
	if n.info.Kind != KindFile {
		return nil, 0, syscall.EISDIR
	}
	if flags&fuse.O_ANYWRITE != 0 {
		return nil, 0, syscall.EROFS
	}
	return &fileHandle{r: NewFileReader(n.store, n.info.File)}, 0, 0
}

// Read implements fs.NodeReader, serving sparse-aware file content.
func (n *fuseNode) Read(ctx context.Context, f fs.FileHandle, dest []byte, off int64) (fuse.ReadResult, syscall.Errno) {
	if n.info.Kind != KindFile || n.info.File == nil {
		return nil, syscall.EISDIR
	}
	var nr int
	var err error
	if fh, ok := f.(*fileHandle); ok && fh.r != nil {
		nr, err = fh.r.ReadAt(ctx, dest, off)
	} else {
		nr, err = ReadAt(ctx, n.store, n.info.File, dest, off)
	}
	if err != nil && !errors.Is(err, io.EOF) {
		// The underlying cause (chunk 404 / fetch error / BLAKE3 mismatch) is
		// otherwise swallowed by the bare EIO the kernel reports as
		// "input/output error"; log it so it shows up in the voilad journal.
		log.Printf("voilad fuse: read inode=%d off=%d: %v", n.inode, off, err)
		return nil, syscall.EIO
	}
	// Use a slice of the caller-provided dest so data is copied in place.
	return fuse.ReadResultData(dest[:nr]), 0
}

// Readlink implements fs.NodeReadlinker.
func (n *fuseNode) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	if n.info.Kind != KindSymlink || n.info.Symlink == nil {
		return nil, syscall.EINVAL
	}
	return []byte(n.info.Symlink.GetTarget()), 0
}

// Getxattr implements fs.NodeGetxattrer.
func (n *fuseNode) Getxattr(ctx context.Context, attr string, dest []byte) (uint32, syscall.Errno) {
	if n.info.Kind != KindFile || n.info.File == nil {
		return 0, syscall.ENODATA
	}
	v, ok := n.info.File.GetXattrs()[attr]
	if !ok {
		return 0, syscall.ENODATA
	}
	if uint32(len(dest)) < uint32(len(v)) {
		return uint32(len(v)), syscall.ERANGE
	}
	copy(dest, v)
	return uint32(len(v)), 0
}

// Listxattr implements fs.NodeListxattrer.
func (n *fuseNode) Listxattr(ctx context.Context, dest []byte) (uint32, syscall.Errno) {
	var names []byte
	if n.info.Kind == KindFile && n.info.File != nil {
		for k := range n.info.File.GetXattrs() {
			names = append(names, k...)
			names = append(names, 0)
		}
	}
	if uint32(len(dest)) < uint32(len(names)) {
		return uint32(len(names)), syscall.ERANGE
	}
	copy(dest, names)
	return uint32(len(names)), 0
}

// Statfs implements fs.NodeStatfser with the placeholder values from plan §6:
// huge free space so installers probing for free space don't refuse to write.
func (n *fuseNode) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	out.Blocks = 1 << 30
	out.Bfree = 1 << 29
	out.Bavail = 1 << 29
	out.Bsize = 4096
	out.NameLen = 255
	return 0
}

// Access implements fs.NodeAccesser. With default_permissions mounted, the
// kernel already enforces perm checks against the Getattr mode; we accept
// here so the daemon does not second-guess the kernel.
func (n *fuseNode) Access(ctx context.Context, mask uint32) syscall.Errno {
	return 0
}
