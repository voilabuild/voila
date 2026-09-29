//go:build linux

package worker

import (
	"context"
	"encoding/hex"
	"fmt"
	"syscall"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
	"voila/internal/mount"
	"voila/internal/nbd"
)

// nbdRegistry is the per-process NBD device registry, shared across all
// contexts. One NBD device per image (refcounted).
var nbdRegistry = nbd.NewRegistry()

// mountErofs builds the EROFS metadata blob from the merged manifest tree,
// acquires an NBD device for it, and mounts the device as EROFS at
// lowerDir. Returns a teardown function and the NBD device key.
//
// The blob is built at mount time: a pure function of the tree. Caching as a
// local chunk is planned but not implemented — each cold mount rebuilds.
func mountErofs(ctx context.Context, store chunkstore.ChunkStore, rootChunk chunkstore.ChunkID, lowerDir string) (teardown func(), err error) {
	// 1. Load the merged manifest tree.
	tree, err := mount.Load(ctx, store, rootChunk)
	if err != nil {
		return nil, fmt.Errorf("erofs: load tree: %w", err)
	}

	// 2. Build the EROFS metadata blob (deterministic; not cached yet).
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		return nil, fmt.Errorf("erofs: build: %w", err)
	}

	// 3. Acquire an NBD device for this image.
	key := hex.EncodeToString(rootChunk[:])
	device, err := nbdRegistry.Acquire(ctx, key, result, store)
	if err != nil {
		return nil, fmt.Errorf("erofs: acquire nbd: %w", err)
	}

	// 4. Mount the NBD device as EROFS (read-only).
	if err := syscall.Mount(device.Path(), lowerDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		nbdRegistry.Release(key)
		return nil, fmt.Errorf("erofs: mount %s at %s: %w", device.Path(), lowerDir, err)
	}

	teardown = func() {
		_ = syscall.Unmount(lowerDir, 0)
		nbdRegistry.Release(key)
	}
	return teardown, nil
}
