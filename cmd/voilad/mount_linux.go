// mount_linux.go is the platform-specific mount implementation for voilad. It
// is built only on Linux (the FUSE daemon is via github.com/hanwen/go-fuse/v2,
// which is Linux-only).

//go:build linux

package main

import (
	"context"
	"fmt"
	"io"

	"voila/internal/chunkstore"
	"voila/internal/mount"
)

// mountAndServe loads the manifest tree, mounts it at mountpoint read-only,
// prints the success line, blocks on SIGINT/SIGTERM (or ctx cancellation),
// then unmounts and prints the completion line.
//
// On non-Linux platforms this hook is provided by mount_stub.go and returns
// errLinuxOnly.
func mountAndServe(out io.Writer, store chunkstore.ChunkStore, rootChunk chunkstore.ChunkID, ref, mountpoint string, allowOther bool) error {
	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootChunk)
	if err != nil {
		return fmt.Errorf("load manifest tree: %w", err)
	}

	srv, err := mount.Mount(mountpoint, tree, store, mount.Options{
		AllowOther: allowOther,
	})
	if err != nil {
		return fmt.Errorf("mount %q: %w", mountpoint, err)
	}
	fmt.Fprintf(out, "mounted %s at %s\n", ref, mountpoint)

	// Block the calling goroutine until SIGINT/SIGTERM, then unmount.
	<-signalsClosed()
	if err := srv.Unmount(); err != nil {
		fmt.Fprintf(out, "unmount: %v\n", err)
		// Best effort: still let the call exit.
	} else {
		fmt.Fprintf(out, "unmounted %s\n", mountpoint)
	}
	return nil
}
