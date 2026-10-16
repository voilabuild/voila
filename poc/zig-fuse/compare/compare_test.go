//go:build zig_fuse_compare

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/mount"
)

func TestDiffRealImageMount(t *testing.T) {
	root := os.Getenv("VOILA_PROOF_ROOT")
	image := os.Getenv("VOILA_PROOF_IMAGE")
	mnt := os.Getenv("VOILA_PROOF_MOUNT")
	if root == "" || image == "" || mnt == "" {
		t.Skip("set VOILA_PROOF_ROOT, VOILA_PROOF_IMAGE, VOILA_PROOF_MOUNT")
	}
	if _, err := os.Stat(mnt); err != nil {
		t.Fatalf("mount %s: %v", mnt, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	imgs, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer imgs.Close()
	_, rootCID, err := imagestore.Resolve(imgs, image)
	if err != nil {
		t.Fatal(err)
	}
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		t.Fatal(err)
	}
	tree.PrefetchManifests(ctx, 32)

	n, err := diffTree(ctx, store, tree, mnt, 65536)
	if err != nil {
		t.Fatal(err)
	}
	if n < 100 {
		t.Fatalf("expected many paths, got %d", n)
	}
}

func TestBusyboxSymlinkOnMount(t *testing.T) {
	mnt := os.Getenv("VOILA_PROOF_MOUNT")
	if mnt == "" {
		t.Skip("set VOILA_PROOF_MOUNT")
	}
	link := filepath.Join(mnt, "bin/arch")
	target, err := os.Readlink(link)
	if err != nil {
		if os.IsPermission(err) {
			t.Skipf("need read access to mount (run test as root): %v", err)
		}
		t.Fatal(err)
	}
	if target != "/bin/busybox" {
		t.Fatalf("bin/arch -> %q, want /bin/busybox", target)
	}
}
