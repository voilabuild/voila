//go:build linux

package nbd

import (
	"context"
	"encoding/hex"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
	"voila/internal/imagestore"
	"voila/internal/mount"
)

// TestE2E_ErofsNBD is an end-to-end test that:
// 1. Opens the ingested alpine image (if present)
// 2. Builds the EROFS blob from the merged manifest tree
// 3. Acquires an NBD device
// 4. Mounts it as EROFS
// 5. Reads the root directory
//
// This test requires: /dev/nbd*, erofs kernel support, and a pre-ingested
// alpine image at VOILA_ROOT. It skips if any prerequisite is missing.
func TestE2E_ErofsNBD(t *testing.T) {
	// Check prerequisites.
	if os.Geteuid() != 0 {
		t.Skip("requires root")
	}
	if _, err := os.Stat("/dev/nbd0"); err != nil {
		t.Skip("requires /dev/nbd0")
	}
	root := os.Getenv("VOILA_ROOT")
	if root == "" {
		t.Skip("requires VOILA_ROOT with ingested alpine image")
	}

	ctx := context.Background()

	// Open the chunk store.
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	defer store.Close()

	// Open imagestore and load the manifest.
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("imagestore.Open: %v", err)
	}
	defer imgStore.Close()

	ref := "registry-1.docker.io/library/alpine:latest"
	im, rootChunk, err := imgStore.LoadImageManifest(ref)
	if err != nil {
		t.Skipf("no alpine image ingested: %v", err)
	}
	_ = im
	t.Logf("Root chunk: %s", hex.EncodeToString(rootChunk[:]))

	// Load the tree.
	tree, err := mount.Load(ctx, store, rootChunk)
	if err != nil {
		t.Fatalf("mount.Load: %v", err)
	}

	// Build the EROFS blob.
	t.Log("Building EROFS blob...")
	result, err := erofsadapter.Build(ctx, tree)
	if err != nil {
		t.Fatalf("erofsadapter.Build: %v", err)
	}
	t.Logf("Metadata: %d bytes, slots: %d, device: %d bytes",
		len(result.Metadata), len(result.SlotTable), result.DeviceSize)

	// Verify the superblock magic.
	if len(result.Metadata) < 1024+128 {
		t.Fatalf("metadata too small: %d", len(result.Metadata))
	}
	sb := result.Metadata[1024:]
	magic := uint32(sb[0]) | uint32(sb[1])<<8 | uint32(sb[2])<<16 | uint32(sb[3])<<24
	if magic != 0xe0f5e1e2 {
		t.Fatalf("bad superblock magic: 0x%08x (expected 0xe0f5e1e2)", magic)
	}
	t.Logf("Superblock magic: OK")

	// Check the patched superblock fields.
	featIncompat := uint32(sb[80]) | uint32(sb[81])<<8 | uint32(sb[82])<<16 | uint32(sb[83])<<24
	extraDevs := uint16(sb[86]) | uint16(sb[87])<<8
	t.Logf("FeatureIncompat: 0x%08x, ExtraDevices: %d", featIncompat, extraDevs)
	if extraDevs != 0 {
		t.Errorf("ExtraDevices should be 0 after patching, got %d", extraDevs)
	}
	if featIncompat&0x08 != 0 {
		t.Errorf("FeatureIncompatDeviceTable should be cleared after patching")
	}

	// Acquire NBD device.
	key := hex.EncodeToString(rootChunk[:])
	reg := NewRegistry()
	device, err := reg.Acquire(ctx, key, result, store)
	if err != nil {
		t.Fatalf("nbd.Acquire: %v", err)
	}
	t.Logf("NBD device: %s", device.Path())
	defer reg.Release(key)

	// Mount as EROFS.
	mountDir := filepath.Join(t.TempDir(), "erofs")
	if err := os.MkdirAll(mountDir, 0755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Logf("Mounting %s at %s", device.Path(), mountDir)

	if err := syscall.Mount(device.Path(), mountDir, "erofs", syscall.MS_RDONLY, ""); err != nil {
		t.Fatalf("mount erofs: %v", err)
	}
	defer syscall.Unmount(mountDir, 0)

	// Read the root directory.
	entries, err := os.ReadDir(mountDir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	t.Logf("Root entries: %d", len(entries))
	for _, e := range entries {
		t.Logf("  %s", e.Name())
	}
	if len(entries) == 0 {
		t.Fatal("no entries in root directory")
	}

	// Try reading /etc/os-release.
	osRelease := filepath.Join(mountDir, "etc", "os-release")
	data, err := os.ReadFile(osRelease)
	if err != nil {
		t.Logf("ReadFile /etc/os-release: %v (may be OK for minimal images)", err)
	} else {
		t.Logf("/etc/os-release:\n%s", string(data[:min(len(data), 200)]))
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
