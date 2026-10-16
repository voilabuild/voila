//go:build zig_fuse_compare

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/mount"
)

// Fair small-file bench:
//   - drop_caches clears kernel page cache only (when permitted).
//   - Go cold: new OS process, fresh chunkstore open, then timed ReadAt loop.
//   - Go warm: second ReadAt loop in that same process (in-process / OS cache warm).
//   - Zig cold: new zig-fuse serve-store (empty chunk_cache), drop_caches, timed os.ReadFile loop.
//   - Zig warm: second ReadAt loop on same mount (Zig chunk_cache + kernel cache warm).

func runFairBench(ctx context.Context, root, image, mountDir, zigFuseBin string, maxFile int64) error {
	if zigFuseBin == "" {
		return fmt.Errorf("fair bench requires -zig-fuse-bin")
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("fair bench must run as root (FUSE mount + drop_caches)")
	}

	files, err := collectBenchFiles(ctx, root, image, maxFile)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("no files <= %d bytes in image", maxFile)
	}

	goCold, goWarm, goBytes, err := benchGoSubprocess(root, image, maxFile)
	if err != nil {
		return fmt.Errorf("go bench: %w", err)
	}

	stopZig, err := startZigFUSE(zigFuseBin, root, image, mountDir)
	if err != nil {
		return fmt.Errorf("zig mount: %w", err)
	}
	defer stopZig()

	dropPageCache()
	zigCold, zigBytes, err := benchFuseReads(ctx, root, image, mountDir, files)
	if err != nil {
		return fmt.Errorf("zig cold: %w", err)
	}
	zigWarm, _, err := benchFuseReads(ctx, root, image, mountDir, files)
	if err != nil {
		return fmt.Errorf("zig warm: %w", err)
	}

	fmt.Printf("bench_fair files=%d bytes=%d max_file=%d\n", len(files), goBytes, maxFile)
	fmt.Printf("method: go_cold=new_go_process+drop_caches; go_warm=same_process; zig_cold=new_zig_fuse+drop_caches; zig_warm=same_zig_process\n")
	fmt.Printf("go_userspace cold=%s warm=%s\n", goCold, goWarm)
	fmt.Printf("zig_fuse     cold=%s warm=%s\n", zigCold, zigWarm)
	if goBytes != zigBytes {
		fmt.Fprintf(os.Stderr, "note: go bytes %d zig bytes %d\n", goBytes, zigBytes)
	}
	return nil
}

func dropPageCache() {
	syscall.Sync()
	if err := os.WriteFile("/proc/sys/vm/drop_caches", []byte("3\n"), 0); err != nil {
		fmt.Fprintf(os.Stderr, "note: drop_caches skipped (%v)\n", err)
	}
}

func collectBenchFiles(ctx context.Context, root, image string, maxFile int64) ([]walkItem, error) {
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return nil, err
	}
	defer store.Close()
	imgs, err := imagestore.Open(root)
	if err != nil {
		return nil, err
	}
	defer imgs.Close()
	_, rootCID, err := imagestore.Resolve(imgs, image)
	if err != nil {
		return nil, err
	}
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		return nil, err
	}
	tree.PrefetchManifests(ctx, 32)
	items, err := collectPaths(ctx, tree, tree.Root(), "")
	if err != nil {
		return nil, err
	}
	var files []walkItem
	for _, it := range items {
		if it.kind != mount.KindFile {
			continue
		}
		info, err := tree.Get(ctx, it.ino)
		if err != nil {
			return nil, err
		}
		if int64(info.File.GetSize()) > maxFile {
			continue
		}
		files = append(files, it)
	}
	return files, nil
}

func benchGoSubprocess(root, image string, maxFile int64) (cold, warm time.Duration, bytes int64, err error) {
	exe, err := os.Executable()
	if err != nil {
		return 0, 0, 0, err
	}
	cmd := exec.Command(exe, "-bench-worker=go", "-root", root, "-image", image, fmt.Sprintf("-max-file=%d", maxFile))
	out, err := cmd.CombinedOutput()
	if err != nil {
		return 0, 0, 0, fmt.Errorf("%w: %s", err, out)
	}
	return parseBenchWorkerOutput(string(out))
}

func parseBenchWorkerOutput(s string) (cold, warm time.Duration, bytes int64, err error) {
	for _, line := range strings.Split(s, "\n") {
		if !strings.HasPrefix(line, "BENCH_GO ") {
			continue
		}
		var coldNs, warmNs int64
		if _, err := fmt.Sscanf(line, "BENCH_GO cold_ns=%d warm_ns=%d bytes=%d", &coldNs, &warmNs, &bytes); err != nil {
			return 0, 0, 0, fmt.Errorf("parse bench line: %w", err)
		}
		return time.Duration(coldNs), time.Duration(warmNs), bytes, nil
	}
	return 0, 0, 0, fmt.Errorf("no BENCH_GO line in worker output: %q", s)
}

// runGoBenchWorker runs in a fresh OS process (-bench-worker=go).

func runGoBenchWorker(root, image string, maxFile int64) error {
	cold, warm, bytes, err := runGoBenchWorkerTimed(root, image, maxFile)
	if err != nil {
		return err
	}
	fmt.Printf("BENCH_GO cold_ns=%d warm_ns=%d bytes=%d\n", cold.Nanoseconds(), warm.Nanoseconds(), bytes)
	return nil
}

func runGoBenchWorkerTimed(root, image string, maxFile int64) (cold, warm time.Duration, bytes int64, err error) {
	ctx := context.Background()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return 0, 0, 0, err
	}
	defer store.Close()
	imgs, err := imagestore.Open(root)
	if err != nil {
		return 0, 0, 0, err
	}
	defer imgs.Close()
	_, rootCID, err := imagestore.Resolve(imgs, image)
	if err != nil {
		return 0, 0, 0, err
	}
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		return 0, 0, 0, err
	}
	tree.PrefetchManifests(ctx, 32)
	files, err := collectBenchFiles(ctx, root, image, maxFile)
	if err != nil {
		return 0, 0, 0, err
	}

	dropPageCache()
	cold, bytes, err = benchGoReads(ctx, store, tree, files)
	if err != nil {
		return 0, 0, 0, err
	}
	warm, bytes2, err := benchGoReads(ctx, store, tree, files)
	if err != nil {
		return 0, 0, 0, err
	}
	if bytes2 != bytes {
		return 0, 0, 0, fmt.Errorf("go warm bytes %d != cold %d", bytes2, bytes)
	}
	return cold, warm, bytes, nil
}

func benchGoReads(ctx context.Context, store chunkstore.ChunkStore, tree *mount.Tree, files []walkItem) (time.Duration, int64, error) {
	var total int64
	start := time.Now()
	for _, it := range files {
		info, err := tree.Get(ctx, it.ino)
		if err != nil {
			return 0, 0, err
		}
		size := int64(info.File.GetSize())
		buf := make([]byte, size)
		n, err := mount.ReadAt(ctx, store, info.File, buf, 0)
		if err != nil && !(err == io.EOF && int64(n) == size) {
			return 0, 0, err
		}
		total += int64(n)
	}
	return time.Since(start), total, nil
}

func benchFuseReads(ctx context.Context, root, image, mountDir string, files []walkItem) (time.Duration, int64, error) {
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return 0, 0, err
	}
	defer store.Close()
	imgs, err := imagestore.Open(root)
	if err != nil {
		return 0, 0, err
	}
	defer imgs.Close()
	_, rootCID, err := imagestore.Resolve(imgs, image)
	if err != nil {
		return 0, 0, err
	}
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		return 0, 0, err
	}

	var total int64
	start := time.Now()
	for _, it := range files {
		info, err := tree.Get(ctx, it.ino)
		if err != nil {
			return 0, 0, err
		}
		rel := strings.TrimPrefix(it.path, "/")
		host := filepath.Join(mountDir, rel)
		buf, err := os.ReadFile(host)
		if err != nil {
			return 0, 0, err
		}
		if int64(len(buf)) != int64(info.File.GetSize()) {
			return 0, 0, fmt.Errorf("%s: size %d != %d", it.path, len(buf), info.File.GetSize())
		}
		total += int64(len(buf))
	}
	return time.Since(start), total, nil
}

func startZigFUSE(zigBin, root, image, mountDir string) (func(), error) {
	_ = exec.Command("fusermount3", "-u", mountDir).Run()
	_ = os.RemoveAll(mountDir)
	if err := os.MkdirAll(mountDir, 0o755); err != nil {
		return nil, err
	}
	cmd := exec.Command(zigBin, "serve-store", root, image, mountDir)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	probe := filepath.Join(mountDir, "etc", "os-release")
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(probe); err == nil {
			return func() {
				_ = exec.Command("fusermount3", "-u", mountDir).Run()
				_ = cmd.Process.Kill()
				_, _ = cmd.Process.Wait()
			}, nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = cmd.Process.Kill()
	return nil, fmt.Errorf("zig-fuse mount did not become ready at %s", mountDir)
}
