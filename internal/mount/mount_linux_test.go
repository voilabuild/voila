//go:build linux

package mount

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/ingest"

	"archive/tar"
)

// TestMountSyntheticImage ingests a synthetic, deterministic tar built in
// memory (files > 1 MiB, a symlink, a hardlink pair) into a temp store and
// mounts the resulting merged tree as a FUSE filesystem, then exercises it
// through the OS.
//
// It skips unless /dev/fuse is present AND the test runs as root, since FUSE
// mounts require both. The tech lead's devcontainer satisfies both.
func TestMountSyntheticImage(t *testing.T) {
	if _, err := os.Stat("/dev/fuse"); err != nil {
		t.Skipf("skipping: /dev/fuse not available: %v", err)
	}
	if os.Geteuid() != 0 {
		t.Skip("skipping: FUSE integration test requires root (CAP_SYS_ADMIN to mount)")
	}

	// runc, fuse3 are preinstalled in the devcontainer; we only need fusermount
	// for go-fuse's helper path on Linux. Skip if absent so this is robust on
	// bare-bones VMs.
	if _, err := exec.LookPath("fusermount"); err != nil && !haveDirectMountCap() {
		t.Skipf("skipping: no fusermount and no syscall.Mount capability: %v", err)
	}

	store, cleanup := openTempStore(t)
	defer cleanup()

	tarBytes := wrapOCILayout(t, buildSyntheticTar(t))
	mr := ingestFromBytes(t, store, tarBytes, "synthetic:latest")

	ctx := context.Background()
	tree, err := Load(ctx, store, mr)
	if err != nil {
		t.Fatalf("Load tree: %v", err)
	}

	mountpoint := t.TempDir()
	srv, err := Mount(mountpoint, tree, store, Options{AllowOther: true})
	if err != nil {
		t.Fatalf("Mount: %v", err)
	}
	defer func() { _ = srv.Unmount() }()

	// Server.Wait runs in a goroutine so we can drive the test concurrently
	// and Unmount at the end.
	waitDone := make(chan struct{})
	go func() { srv.Wait(); close(waitDone) }()
	// Give the kernel a tick to publish the mount.
	waitForMount(t, mountpoint)

	// 1. root listing contains our expected names.
	rootEntries, err := os.ReadDir(mountpoint)
	if err != nil {
		t.Fatalf("ReadDir root: %v", err)
	}
	gotNames := map[string]bool{}
	for _, e := range rootEntries {
		gotNames[e.Name()] = true
	}
	for _, want := range []string{"small.txt", "big.bin", "link.txt", "hard_a", "hard_b"} {
		if !gotNames[want] {
			t.Errorf("root missing entry %q (have %v)", want, gotNames)
		}
	}

	// 2. Multi-block file content matches expectation (3 MiB of 'A').
	big, err := os.ReadFile(filepath.Join(mountpoint, "big.bin"))
	if err != nil {
		t.Fatalf("ReadFile big.bin: %v", err)
	}
	wantBig := bytes.Repeat([]byte("A"), 3<<20)
	if !bytes.Equal(big, wantBig) {
		t.Errorf("big.bin mismatch (got len=%d want=%d)", len(big), len(wantBig))
	}

	// 3. Symlink resolves to its target.
	target, err := os.Readlink(filepath.Join(mountpoint, "link.txt"))
	if err != nil {
		t.Fatalf("Readlink: %v", err)
	}
	if target != "small.txt" {
		t.Errorf("link target = %q, want small.txt", target)
	}

	// 4. Hardlink pair shares the same inode and Nlink==2.
	stA, stB, err := lstatPair(t, mountpoint, "hard_a", "hard_b")
	if err != nil {
		t.Fatalf("lstat hard*: %v", err)
	}
	if stA.Ino != stB.Ino {
		t.Errorf("hardlink inodes differ: %d vs %d", stA.Ino, stB.Ino)
	}
	if stA.Nlink != 2 || stB.Nlink != 2 {
		t.Errorf("hardlink nlink want 2/2, got %d/%d", stA.Nlink, stB.Nlink)
	}

	// 5. Metadata correctness (uid/gid/mode/inode of regular file).
	stSmall, err := os.Lstat(filepath.Join(mountpoint, "small.txt"))
	if err != nil {
		t.Fatalf("lstat small.txt: %v", err)
	}
	st := mustStatT(t, stSmall)
	if st.Mode&0o7777 != 0o644 {
		t.Errorf("small.txt mode=%o, want 0o644", st.Mode&0o7777)
	}
	if st.Ino == 0 {
		t.Errorf("small.txt inode = 0")
	}

	// 6. Clean unmount: Wait must return shortly after Unmount.
	if err := srv.Unmount(); err != nil {
		t.Fatalf("Unmount: %v", err)
	}
	select {
	case <-waitDone:
	case <-time.After(3 * time.Second):
		t.Error("Wait did not return within 3s of Unmount")
	}
}

// wrapOCILayout wraps a single raw layer tar in a minimal OCI image-layout
// tarball (oci-layout + index.json + config/manifest/layer blobs), which is
// what ingest.Ingest expects — a bare layer tar is not an image.
func wrapOCILayout(t *testing.T, layer []byte) []byte {
	t.Helper()
	sha := func(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

	config := []byte(`{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}`)
	manifest := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",`+
			`"config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},`+
			`"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		sha(config), len(config), sha(layer), len(layer)))
	index := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%d}]}`,
		sha(manifest), len(manifest)))

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	add := func(name string, body []byte) {
		t.Helper()
		if err := tw.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(body))}); err != nil {
			t.Fatalf("outer WriteHeader %q: %v", name, err)
		}
		if _, err := tw.Write(body); err != nil {
			t.Fatalf("outer Write %q: %v", name, err)
		}
	}
	add("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	add("index.json", index)
	add("blobs/sha256/"+sha(config), config)
	add("blobs/sha256/"+sha(manifest), manifest)
	add("blobs/sha256/"+sha(layer), layer)
	if err := tw.Close(); err != nil {
		t.Fatalf("close outer tar: %v", err)
	}
	return buf.Bytes()
}

// openTempStore opens a LocalStore in a temp dir and returns a cleanup fn.
func openTempStore(t *testing.T) (*chunkstore.LocalStore, func()) {
	t.Helper()
	dir := t.TempDir()
	store, err := chunkstore.OpenLocal(dir)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	return store, func() {
		_ = store.Close()
	}
}

func buildSyntheticTar(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	defer tw.Close()

	write := func(h *tar.Header, body []byte) {
		t.Helper()
		if err := tw.WriteHeader(h); err != nil {
			t.Fatalf("WriteHeader %q: %v", h.Name, err)
		}
		if len(body) > 0 {
			if _, err := tw.Write(body); err != nil {
				t.Fatalf("Write %q: %v", h.Name, err)
			}
		}
	}

	// Small text file.
	write(&tar.Header{
		Name:     "small.txt",
		Typeflag: tar.TypeReg,
		Mode:     0o644,
		Size:     6,
		Uid:      0, Gid: 0,
		ModTime: time.Unix(0, 0),
	}, []byte("hello\n"))

	// 3 MiB file (spans 3 chunks of 1 MiB). Content: repeating 'A'.
	big := bytes.Repeat([]byte("A"), 3<<20)
	write(&tar.Header{
		Name:     "big.bin",
		Typeflag: tar.TypeReg,
		Mode:     0o644,
		Size:     int64(len(big)),
		ModTime:  time.Unix(0, 0),
	}, big)

	// Symlink: link.txt → small.txt
	write(&tar.Header{
		Name:     "link.txt",
		Typeflag: tar.TypeSymlink,
		Mode:     0o777,
		Linkname: "small.txt",
		ModTime:  time.Unix(0, 0),
	}, nil)

	// Hardlink pair: hard_a is regular, hard_b is a tar-TypeLink to hard_a.
	body := []byte("hardlink content\n")
	write(&tar.Header{
		Name:     "hard_a",
		Typeflag: tar.TypeReg,
		Mode:     0o644,
		Size:     int64(len(body)),
		ModTime:  time.Unix(0, 0),
	}, body)
	write(&tar.Header{
		Name:     "hard_b",
		Typeflag: tar.TypeLink,
		Linkname: "hard_a",
		ModTime:  time.Unix(0, 0),
	}, nil)

	if err := tw.Close(); err != nil {
		t.Fatalf("Close tar writer: %v", err)
	}
	return buf.Bytes()
}

// ingestFromBytes writes tarBytes to a temp file, ingests via the standard
// pipeline, and returns the merged-root manifest chunk id.
func ingestFromBytes(t *testing.T, store chunkstore.ChunkStore, tarBytes []byte, ref string) chunkstore.ChunkID {
	t.Helper()
	tmp := filepath.Join(t.TempDir(), "synthetic.tar")
	if err := os.WriteFile(tmp, tarBytes, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	res, err := ingest.Ingest(context.Background(), tmp, store, ingest.Options{Ref: ref})
	if err != nil {
		t.Fatalf("ingest.Ingest: %v", err)
	}
	return res.MergedRootManifestChunk
}

func lstatPair(t *testing.T, root, a, b string) (syscall.Stat_t, syscall.Stat_t, error) {
	t.Helper()
	sa, err := os.Lstat(filepath.Join(root, a))
	if err != nil {
		return syscall.Stat_t{}, syscall.Stat_t{}, err
	}
	sb, err := os.Lstat(filepath.Join(root, b))
	if err != nil {
		return syscall.Stat_t{}, syscall.Stat_t{}, err
	}
	return *mustStatT(t, sa), *mustStatT(t, sb), nil
}

func mustStatT(t *testing.T, fi os.FileInfo) *syscall.Stat_t {
	t.Helper()
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("expected *syscall.Stat_t, got %T", fi.Sys())
	}
	return st
}

// haveDirectMountCap reports whether syscall.Mount is available — approximated
// here by being root, which is already required.
func haveDirectMountCap() bool { return os.Geteuid() == 0 }

// waitForMount blocks (briefly) until mountpoint is populated.
func waitForMount(t *testing.T, mountpoint string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if entries, err := os.ReadDir(mountpoint); err == nil && len(entries) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Logf("waited 3s for mount population at %s; entries=%v", mountpoint, listOrErr(mountpoint))
}

func listOrErr(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err.Error()
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return strings.Join(names, ",")
}
