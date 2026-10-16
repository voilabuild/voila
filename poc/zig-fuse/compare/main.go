//go:build zig_fuse_compare

// Compare a Zig FUSE mount against the Go userspace mount tree (mount.Load + ReadAt).
//
//	go run -tags zig_fuse_compare ./poc/zig-fuse/compare \
//	  -root /tmp/voila-store -image alpine:3.20 -mount /tmp/zig-mnt
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/mount"
	voilapb "voila/internal/proto"
)

func main() {
	root := flag.String("root", "", "voila store root")
	image := flag.String("image", "", "image ref in images.db")
	mountDir := flag.String("mount", "", "Zig FUSE mountpoint (read-only)")
	bench := flag.Bool("bench", false, "time small-file walk+read (Go userspace vs mount tree)")
	maxFile := flag.Int64("max-file", 65536, "include regular files up to this size in diff/bench")
	flag.Parse()
	if *root == "" || *image == "" {
		fmt.Fprintln(os.Stderr, "need -root and -image")
		os.Exit(2)
	}
	if *mountDir == "" {
		fmt.Fprintln(os.Stderr, "need -mount")
		os.Exit(2)
	}

	store, err := chunkstore.OpenLocal(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open store: %v\n", err)
		os.Exit(1)
	}
	defer store.Close()

	imgs, err := imagestore.Open(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open imagestore: %v\n", err)
		os.Exit(1)
	}
	defer imgs.Close()
	_, rootCID, err := imagestore.Resolve(imgs, *image)
	if err != nil {
		fmt.Fprintf(os.Stderr, "resolve image: %v\n", err)
		os.Exit(1)
	}

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load tree: %v\n", err)
		os.Exit(1)
	}
	tree.PrefetchManifests(ctx, 32)

	if *bench {
		if err := runBench(ctx, store, tree, *mountDir, *maxFile); err != nil {
			fmt.Fprintf(os.Stderr, "bench: %v\n", err)
			os.Exit(1)
		}
		return
	}

	n, err := diffTree(ctx, store, tree, *mountDir, *maxFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "diff: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("diff ok: %d paths checked (bytes, symlink targets, mode bits)\n", n)
}

type walkItem struct {
	path string
	ino  uint64
	kind mount.NodeKind
}

func unixPerm(host string) (uint32, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(host, &st); err != nil {
		return 0, err
	}
	return st.Mode & 0o7777, nil
}

func unixLperm(host string) (uint32, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(host, &st); err != nil {
		return 0, err
	}
	return st.Mode & 0o7777, nil
}

func collectPaths(ctx context.Context, tree *mount.Tree, dirIno uint64, prefix string) ([]walkItem, error) {
	entries, err := tree.ReadDir(ctx, dirIno)
	if err != nil {
		return nil, err
	}
	var out []walkItem
	for _, e := range entries {
		p := prefix + "/" + e.Name
		if prefix == "" {
			p = "/" + e.Name
		}
		out = append(out, walkItem{path: p, ino: e.Inode, kind: e.Kind})
		if e.Kind == mount.KindDir {
			sub, err := collectPaths(ctx, tree, e.Inode, p)
			if err != nil {
				return nil, err
			}
			out = append(out, sub...)
		}
	}
	return out, nil
}

func diffTree(ctx context.Context, store chunkstore.ChunkStore, tree *mount.Tree, mountDir string, maxFile int64) (int, error) {
	items, err := collectPaths(ctx, tree, tree.Root(), "")
	if err != nil {
		return 0, err
	}
	sort.Slice(items, func(i, j int) bool { return items[i].path < items[j].path })

	checked := 0
	for _, it := range items {
		info, err := tree.Get(ctx, it.ino)
		if err != nil {
			return checked, fmt.Errorf("%s: get inode: %w", it.path, err)
		}
		rel := strings.TrimPrefix(it.path, "/")
		host := filepath.Join(mountDir, rel)
		if rel == "" {
			host = mountDir
		}

		if li, err := os.Lstat(host); err == nil && li.Mode()&os.ModeSymlink != 0 {
			target, err := os.Readlink(host)
			if err != nil {
				return checked, fmt.Errorf("%s: readlink mount: %w", it.path, err)
			}
			if info.Kind == mount.KindSymlink {
				if target != info.Symlink.GetTarget() {
					return checked, fmt.Errorf("%s: symlink target mount=%q want=%q", it.path, target, info.Symlink.GetTarget())
				}
			}
			gotPerm, err := unixLperm(host)
			if err != nil {
				return checked, fmt.Errorf("%s: unix lstat %q: %w", it.path, host, err)
			}
			if gotPerm != 0o777 {
				return checked, fmt.Errorf("%s: symlink mode mount=%o want=%o", it.path, gotPerm, 0o777)
			}
			checked++
			continue
		}

		switch info.Kind {
		case mount.KindDir:
			st, err := os.Stat(host)
			if err != nil {
				return checked, fmt.Errorf("%s: stat mount %q: %w", it.path, host, err)
			}
			if !st.IsDir() {
				return checked, fmt.Errorf("%s: mount not a directory", it.path)
			}
			gotPerm, err := unixPerm(host)
			if err != nil {
				return checked, fmt.Errorf("%s: unix stat %q: %w", it.path, host, err)
			}
			wantPerm := uint32(info.Dir.GetMode() & 0o7777)
			if gotPerm != wantPerm {
				return checked, fmt.Errorf("%s: mode mount=%o want=%o host=%q", it.path, gotPerm, wantPerm, host)
			}
		case mount.KindSymlink:
			return checked, fmt.Errorf("%s: symlink missing on mount", it.path)
		case mount.KindFile:
			size := int64(info.File.GetSize())
			if size > maxFile {
				continue
			}
			st, err := os.Stat(host)
			if err != nil {
				return checked, fmt.Errorf("%s: stat mount: %w", it.path, err)
			}
			if !st.Mode().IsRegular() {
				return checked, fmt.Errorf("%s: mount not regular file", it.path)
			}
			if st.Size() != int64(size) {
				return checked, fmt.Errorf("%s: size mount=%d want=%d", it.path, st.Size(), size)
			}
			gotPerm, err := unixPerm(host)
			if err != nil {
				return checked, fmt.Errorf("%s: unix stat %q: %w", it.path, host, err)
			}
			wantPerm := uint32(info.File.GetMode() & 0o7777)
			if gotPerm != wantPerm {
				return checked, fmt.Errorf("%s: mode mount=%o want=%o", it.path, gotPerm, wantPerm)
			}
			if size == 0 {
				checked++
				continue
			}
			goSum, err := fileSHA256Go(ctx, store, info.File, size)
			if err != nil {
				return checked, fmt.Errorf("%s: go read: %w", it.path, err)
			}
			fuseSum, err := fileSHA256Path(host, size)
			if err != nil {
				return checked, fmt.Errorf("%s: mount read: %w", it.path, err)
			}
			if goSum != fuseSum {
				return checked, fmt.Errorf("%s: content mismatch go=%s mount=%s", it.path, goSum, fuseSum)
			}
		case mount.KindDevice:
			st, err := os.Stat(host)
			if err != nil {
				return checked, fmt.Errorf("%s: stat device: %w", it.path, err)
			}
			want := info.Device
			var wantType fs.FileMode
			if want.GetIsChar() {
				wantType = os.ModeCharDevice
			} else {
				wantType = os.ModeDevice
			}
			if st.Mode()&os.ModeType != wantType {
				return checked, fmt.Errorf("%s: device type mismatch", it.path)
			}
			gotPerm, err := unixPerm(host)
			if err != nil {
				return checked, fmt.Errorf("%s: unix stat %q: %w", it.path, host, err)
			}
			wantPerm := uint32(want.GetMode() & 0o7777)
			if gotPerm != wantPerm {
				return checked, fmt.Errorf("%s: device mode mount=%o want=%o", it.path, gotPerm, wantPerm)
			}
		default:
			return checked, fmt.Errorf("%s: unknown kind %v", it.path, info.Kind)
		}
		checked++
	}
	return checked, nil
}

func fileSHA256Go(ctx context.Context, store chunkstore.ChunkStore, f *voilapb.File, size int64) (string, error) {
	if f == nil {
		return "", fmt.Errorf("nil file")
	}
	buf := make([]byte, size)
	n, err := mount.ReadAt(ctx, store, f, buf, 0)
	if err != nil && !(err == io.EOF && int64(n) == size) {
		return "", err
	}
	if int64(n) != size {
		return "", fmt.Errorf("short read %d/%d", n, size)
	}
	sum := sha256.Sum256(buf)
	return hex.EncodeToString(sum[:]), nil
}

func fileSHA256Path(path string, size int64) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	buf := make([]byte, size)
	n, err := f.Read(buf)
	if err != nil {
		return "", err
	}
	if int64(n) != size {
		return "", fmt.Errorf("short read %d/%d", n, size)
	}
	sum := sha256.Sum256(buf)
	return hex.EncodeToString(sum[:]), nil
}

func runBench(ctx context.Context, store chunkstore.ChunkStore, tree *mount.Tree, mountDir string, maxFile int64) error {
	items, err := collectPaths(ctx, tree, tree.Root(), "")
	if err != nil {
		return err
	}
	var files []walkItem
	for _, it := range items {
		if it.kind != mount.KindFile {
			continue
		}
		info, err := tree.Get(ctx, it.ino)
		if err != nil {
			return err
		}
		if int64(info.File.GetSize()) > maxFile {
			continue
		}
		files = append(files, it)
	}
	sort.Slice(files, func(i, j int) bool { return files[i].path < files[j].path })

	dropCaches := func() {
		syscall.Sync()
		if err := os.WriteFile("/proc/sys/vm/drop_caches", []byte("3\n"), 0); err != nil {
			fmt.Fprintf(os.Stderr, "note: drop_caches skipped (%v)\n", err)
		}
	}

	goOnce := func() (time.Duration, int64, error) {
		var bytes int64
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
			bytes += int64(n)
		}
		return time.Since(start), bytes, nil
	}

	zigOnce := func() (time.Duration, int64, error) {
		var bytes int64
		start := time.Now()
		for _, it := range files {
			info, err := tree.Get(ctx, it.ino)
			if err != nil {
				return 0, 0, err
			}
			host := filepath.Join(mountDir, filepath.FromSlash(strings.TrimPrefix(it.path, "/")))
			buf, err := os.ReadFile(host)
			if err != nil {
				return 0, 0, err
			}
			if int64(len(buf)) != int64(info.File.GetSize()) {
				return 0, 0, fmt.Errorf("%s: size %d != %d", it.path, len(buf), info.File.GetSize())
			}
			bytes += int64(len(buf))
		}
		return time.Since(start), bytes, nil
	}

	dropCaches()
	goCold, goBytes, err := goOnce()
	if err != nil {
		return err
	}
	dropCaches()
	zigCold, _, err := zigOnce()
	if err != nil {
		return err
	}
	dropCaches()
	goWarm, _, err := goOnce()
	if err != nil {
		return err
	}
	dropCaches()
	zigWarm, _, err := zigOnce()
	if err != nil {
		return err
	}

	fmt.Printf("bench files=%d bytes=%d max_file=%d\n", len(files), goBytes, maxFile)
	fmt.Printf("go_userspace cold=%s warm=%s\n", goCold, goWarm)
	fmt.Printf("zig_fuse     cold=%s warm=%s\n", zigCold, zigWarm)
	return nil
}
