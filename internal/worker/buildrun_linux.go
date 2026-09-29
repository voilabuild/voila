//go:build linux

package worker

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	specs "github.com/opencontainers/runtime-spec/specs-go"

	"voila/internal/chunkstore"
	"voila/internal/ingest"
	"voila/internal/mount"
	"voila/internal/runtime"
)

// BuildRunSpec is the daemon-side input for a Dockerfile RUN step.
type BuildRunSpec struct {
	RootChunk, ConfigChunk chunkstore.ChunkID
	Argv                   []string
	Env                    []string
	Cwd                    string
	User                   string
	HostNetwork            bool
	Stdin                  io.Reader
}

// BuildRun mounts the parent image, executes argv in a throwaway overlay
// container, snapshots the overlay upper into a layer manifest chunk, and
// returns the layer chunk + exit code.
func (l *platformLauncher) BuildRun(ctx context.Context, spec BuildRunSpec, sink IOSink) (chunkstore.ChunkID, int, error) {
	store := l.store
	id, err := newContextID()
	if err != nil {
		return chunkstore.ChunkID{}, 0, err
	}
	ctxDir := filepath.Join(l.root, "build", id)
	lowerDir := filepath.Join(ctxDir, "lower")
	upperDir := filepath.Join(ctxDir, "upper")
	workDir := filepath.Join(ctxDir, "work")
	rootfsDir := filepath.Join(ctxDir, "rootfs")
	bundleDir := filepath.Join(ctxDir, "bundle")

	if err := os.MkdirAll(ctxDir, 0o755); err != nil {
		return chunkstore.ChunkID{}, 0, err
	}
	unmountCtx := func() {
		_ = syscall.Unmount(ctxDir, 0)
	}
	if err := syscall.Mount("tmpfs", ctxDir, "tmpfs", 0, ""); err != nil {
		_ = os.RemoveAll(ctxDir)
		return chunkstore.ChunkID{}, 0, fmt.Errorf("mount tmpfs: %w", err)
	}
	for _, d := range []string{lowerDir, upperDir, workDir, rootfsDir, bundleDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			unmountCtx()
			return chunkstore.ChunkID{}, 0, err
		}
	}

	var unmountLower func()
	if mountBackend() == "erofs" {
		ero, err := mountErofs(ctx, store, spec.RootChunk, lowerDir)
		if err != nil {
			unmountCtx()
			return chunkstore.ChunkID{}, 0, err
		}
		unmountLower = ero
	} else {
		tree, err := mount.Load(ctx, store, spec.RootChunk)
		if err != nil {
			unmountCtx()
			return chunkstore.ChunkID{}, 0, err
		}
		srv, err := mount.Mount(lowerDir, tree, store, mount.Options{AllowOther: true})
		if err != nil {
			unmountCtx()
			return chunkstore.ChunkID{}, 0, err
		}
		unmountLower = func() { _ = srv.Unmount() }
	}

	overlayData := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lowerDir, upperDir, workDir)
	if err := syscall.Mount("overlay", rootfsDir, "overlay", 0, overlayData); err != nil {
		unmountLower()
		unmountCtx()
		return chunkstore.ChunkID{}, 0, fmt.Errorf("mount overlay: %w", err)
	}
	unmountAll := func() {
		_ = syscall.Unmount(rootfsDir, 0)
		unmountLower()
		unmountCtx()
	}

	// Build RUN uses host networking but tools like apk/apt still read DNS from
	// /etc/resolv.conf inside the rootfs. Images ingested from Docker registries
	// often ship nameserver 127.0.0.11, which is unreachable outside Docker's
	// embedded resolver.
	if data, err := os.ReadFile("/etc/resolv.conf"); err == nil {
		resolv := filepath.Join(rootfsDir, "etc", "resolv.conf")
		_ = os.MkdirAll(filepath.Dir(resolv), 0o755)
		_ = os.WriteFile(resolv, data, 0o644)
	}

	cwd := spec.Cwd
	if cwd == "" {
		cwd = "/"
	}
	ocispec, err := runtime.BuildSpec(runtime.BundleOpts{
		RootfsPath:  rootfsDir,
		Args:        spec.Argv,
		Env:         spec.Env,
		Cwd:         cwd,
		Writable:    true,
		HostNetwork: true, // build RUN shares host network (apt-get, curl, …)
	})
	if err != nil {
		unmountAll()
		return chunkstore.ChunkID{}, 0, err
	}
	if u := parseOCIUser(spec.User); u != nil {
		ocispec.Process.User = *u
	}
	if err := runtime.WriteBundle(bundleDir, ocispec); err != nil {
		unmountAll()
		return chunkstore.ChunkID{}, 0, err
	}

	runner := runtime.NewRunc()
	defer func() {
		_ = runner.Delete(ctx, id, true)
		unmountAll()
		_ = os.RemoveAll(ctxDir)
	}()

	stdoutW := &sinkWriter{sink: sink, stderr: false}
	stderrW := &sinkWriter{sink: sink, stderr: true}
	code, err := runner.Run(ctx, id, bundleDir, runtime.StdIO{
		In:  spec.Stdin,
		Out: stdoutW,
		Err: stderrW,
	})
	if err != nil {
		return chunkstore.ChunkID{}, 0, err
	}
	if code != 0 {
		return chunkstore.ChunkID{}, code, nil
	}

	res, err := ingest.WalkOverlayUpper(ctx, store, upperDir)
	if err != nil {
		return chunkstore.ChunkID{}, code, err
	}
	layerChunk, err := ingest.BuildAndStoreLayerManifest(res.Tree, store)
	if err != nil {
		return chunkstore.ChunkID{}, code, err
	}
	return layerChunk, code, nil
}

func parseOCIUser(user string) *specs.User {
	user = strings.TrimSpace(user)
	if user == "" {
		return nil
	}
	parts := strings.SplitN(user, ":", 2)
	u := &specs.User{}
	if uid, err := strconv.ParseUint(parts[0], 10, 32); err == nil {
		u.UID = uint32(uid)
	} else {
		u.Username = parts[0]
	}
	if len(parts) == 2 {
		if gid, err := strconv.ParseUint(parts[1], 10, 32); err == nil {
			u.GID = uint32(gid)
		}
	}
	return u
}
