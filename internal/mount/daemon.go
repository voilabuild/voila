//go:build linux

package mount

import (
	"context"
	"errors"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"

	"voila/internal/chunkstore"
)

// Options configures mount-time behaviour of the read-only FUSE daemon.
type Options struct {
	// AllowOther adds the kernel mount option allow_other so non-root users
	// (including container uids in other namespaces) can traverse the mount.
	AllowOther bool
	// FSName is the fsname shown in /proc/mounts. Defaults to "voilafs".
	FSName string
	// Debug enables go-fuse verbose debug logging on the server's logger.
	Debug bool
}

// Server is the running FUSE mount. Wait blocks until the filesystem is
// unmounted; Unmount requests an unmount.
type Server struct {
	srv *fuse.Server
}

// Mount mounts tree as a read-only FUSE filesystem at mountpoint. The returned
// Server has not yet been served yet; call Wait to drive the request loop
// (Mount starts a background goroutine via fs.Mount), or call Unmount to
// tear the mount down without serving.
//
// store is used to fetch file-content chunks on demand by Read ops in ops.go.
func Mount(mountpoint string, tree *Tree, store chunkstore.ChunkStore, opts Options) (*Server, error) {
	if tree == nil {
		return nil, errors.New("mount: nil tree")
	}
	if store == nil {
		return nil, errors.New("mount: nil chunk store")
	}
	if mountpoint == "" {
		return nil, errors.New("mount: empty mountpoint")
	}

	rootInfo, err := tree.Get(context.Background(), tree.Root())
	if err != nil {
		return nil, err
	}
	root := &fuseNode{
		tree:  tree,
		store: store,
		inode: tree.Root(),
		info:  rootInfo,
	}

	if opts.FSName == "" {
		opts.FSName = "voilafs"
	}

	oneHour := time.Hour
	fsOpts := &fs.Options{
		MountOptions: fuse.MountOptions{
			AllowOther: opts.AllowOther,
			Options:    []string{"ro", "default_permissions"},
			FsName:     opts.FSName,
			Debug:      opts.Debug,
			// MaxWrite also sizes max_pages, which caps kernel READ windows.
			// 1 MiB aligns kernel reads with our chunk size so a sequential
			// read touches each chunk once instead of eight times.
			MaxWrite: 1 << 20,
			// DirectMount uses syscall.Mount directly when possible; we prefer
			// the fusermount helper path so non-root-capable fallback chains
			// remain available, but this stays the default (false).
		},
		AttrTimeout:     &oneHour,
		EntryTimeout:    &oneHour,
		NegativeTimeout: &oneHour,
		RootStableAttr:  &fs.StableAttr{Ino: tree.Root()},
	}

	srv, err := fs.Mount(mountpoint, root, fsOpts)
	if err != nil {
		return nil, err
	}
	return &Server{srv: srv}, nil
}

// Wait blocks until the filesystem is unmounted (kernel drops the mount).
func (s *Server) Wait() {
	if s == nil || s.srv == nil {
		return
	}
	s.srv.Wait()
}

// Unmount requests the kernel to unmount the filesystem. Once it returns
// successfully, Wait() will return.
func (s *Server) Unmount() error {
	if s == nil || s.srv == nil {
		return errors.New("mount: server not initialized")
	}
	return s.srv.Unmount()
}
