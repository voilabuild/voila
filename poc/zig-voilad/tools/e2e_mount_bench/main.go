//go:build linux

// e2e_mount_bench times Go FUSE or EROFS mount: process start → probe file read.
package main

import (
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/erofsadapter"
	"voila/internal/imagestore"
	"voila/internal/mount"
	"voila/internal/nbd"
	"voila/internal/registry"
)

var nbdReg = nbd.NewRegistry()

func main() {
	root := flag.String("root", "", "voila store root")
	image := flag.String("image", "", "image ref")
	backend := flag.String("backend", "fuse", "fuse or erofs")
	probe := flag.String("probe", "etc/os-release", "path under mount to read")
	flag.Parse()
	if *root == "" || *image == "" {
		fmt.Fprintln(os.Stderr, "need -root and -image")
		os.Exit(2)
	}

	start := time.Now()
	mnt := "/tmp/go-voilad-bench-mnt"
	_ = os.RemoveAll(mnt)
	if err := os.MkdirAll(mnt, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir: %v\n", err)
		os.Exit(1)
	}
	defer func() {
		_ = syscall.Unmount(mnt, 0)
		_ = os.RemoveAll(mnt)
	}()

	ctx := context.Background()
	imgStore, err := imagestore.Open(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "image store: %v\n", err)
		os.Exit(1)
	}
	defer imgStore.Close()

	im, rootChunk, err := imagestore.Resolve(imgStore, *image)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve: %v\n", err)
		os.Exit(1)
	}
	_ = im

	store, err := chunkstore.OpenLocal(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "chunk store: %v\n", err)
		os.Exit(1)
	}
	defer store.Close()

	var chunkStore chunkstore.ChunkStore = store
	if creds, err := cli.LoadRegistryCreds(*root); err == nil && creds.Registry != "" {
		client, err := registry.NewClient(creds.Registry, registry.WithToken(creds.Token))
		if err == nil {
			defer client.Close()
			chunkStore = chunkstore.NewCached(store, client)
		}
	}

	var unmount func()
	switch *backend {
	case "fuse", "FUSE":
		unmount, err = mountFuse(ctx, chunkStore, rootChunk, mnt)
	case "erofs", "EROFS":
		unmount, err = mountErofs(ctx, chunkStore, rootChunk, mnt)
	default:
		fmt.Fprintf(os.Stderr, "unknown backend %q\n", *backend)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "mount: %v\n", err)
		os.Exit(1)
	}
	defer unmount()

	probePath := filepath.Join(mnt, *probe)
	var data []byte
	deadline := time.Now().Add(4 * time.Second)
	for {
		data, err = os.ReadFile(probePath)
		if err == nil && len(data) > 0 {
			break
		}
		if time.Now().After(deadline) {
			fmt.Fprintf(os.Stderr, "rootfs not ready: %v\n", err)
			os.Exit(1)
		}
		time.Sleep(10 * time.Millisecond)
	}

	ms := float64(time.Since(start).Microseconds()) / 1000.0
	fmt.Printf("rootfs_ready_ms=%.3f backend=%s bytes=%d\n", ms, *backend, len(data))
}

func mountFuse(ctx context.Context, store chunkstore.ChunkStore, root chunkstore.ChunkID, mnt string) (func(), error) {
	tree, err := mount.Load(ctx, store, root)
	if err != nil {
		return nil, err
	}
	srv, err := mount.Mount(mnt, tree, store, mount.Options{AllowOther: true})
	if err != nil {
		return nil, err
	}
	return func() { _ = srv.Unmount() }, nil
}

func mountErofs(ctx context.Context, store chunkstore.ChunkStore, rootChunk chunkstore.ChunkID, lowerDir string) (func(), error) {
	tree, err := mount.Load(ctx, store, rootChunk)
	if err != nil {
		return nil, err
	}
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		return nil, err
	}
	key := hex.EncodeToString(rootChunk[:])
	device, err := nbdReg.Acquire(ctx, key, result, store)
	if err != nil {
		return nil, err
	}
	if err := syscall.Mount(device.Path(), lowerDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		nbdReg.Release(key)
		return nil, err
	}
	return func() {
		_ = syscall.Unmount(lowerDir, 0)
		nbdReg.Release(key)
	}, nil
}
