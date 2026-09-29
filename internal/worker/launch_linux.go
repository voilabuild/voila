// launch_linux.go is the Linux platform Launcher: the daemon-owned counterpart
// of cmd/voila's run_linux.go. It mounts the merged-root FUSE view, builds the
// OCI bundle, drives runc in the foreground, polls runc state for the
// container init pid, and tears everything down on exit. Exec launches an
// additional process inside an existing container via `runc exec`.

//go:build linux

package worker

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/mount"
	"voila/internal/runtime"
)

// platformLauncher is the daemon-owned Linux launcher. It carries the voila
// root + chunk store and a small per-context registry so Exec (which only
// receives a context id, not the resolved image chunks) can re-derive the
// image config / bundle paths for a running context.
type platformLauncher struct {
	root  string
	store chunkstore.ChunkStore

	mu     sync.Mutex
	states map[string]*launchState
}

// launchState records per-context runtime artifacts so Exec can re-derive
// the exec process spec from the image config without re-resolving and so
// the teardown defer always knows the right paths.
type launchState struct {
	cfg         *runtime.ImageConfig // parsed image config (env/cwd basis)
	bundleDir   string
	rootfsDir   string
	ctxDir      string
	rootChunk   chunkstore.ChunkID
	configChunk chunkstore.ChunkID
}

// newPlatformLauncher constructs a platformLauncher bound to root and store.
// Called by NewServer (server.go) when building the default Worker.
func newPlatformLauncher(root string, store chunkstore.ChunkStore) *platformLauncher {
	return &platformLauncher{root: root, store: store, states: map[string]*launchState{}}
}

// Launch mirrors run_linux.go: load+mount the merged root, build+write the
// OCI bundle, drive runc in the foreground, poll runc state for the init pid
// to fire sink.Started, and tear down via defer on every exit path.
func (l *platformLauncher) Launch(ctx context.Context, spec LaunchSpec, sink IOSink) (int, error) {
	// Per-context store: when the worker hands us a counting-wrapped store
	// (spec.Store), read chunks through it so Stats() reflects what this
	// run touched; otherwise use this launcher's own cfg-bound store.
	// NEVER Close spec.Store — the inner store is the daemon's shared one.
	store := spec.Store
	if store == nil {
		store = l.store
	}
	ctxDir := filepath.Join(l.root, "ctx", spec.ID)
	rootfsDir := filepath.Join(ctxDir, "rootfs")
	bundleDir := filepath.Join(ctxDir, "bundle")
	// The rootfs is a writable overlay stacked over the read-only FUSE lower
	// (see the overlay mount below). lower is the FUSE mountpoint; upper +
	// work are the overlay's writable copy-up surface. The whole context
	// dir is mounted on tmpfs so upper+work sit on a filesystem that
	// supports being an overlay upperdir: overlayfs rejects an upperdir on
	// an overlay-backed fs (e.g. Docker's overlay2 storage driver inside a
	// privileged container) with "filesystem on '<upper>' not supported as
	// upperdir". tmpfs is supported as an overlay upper everywhere; the
	// context is ephemeral anyway (torn down with the run), so RAM-backing
	// matches the writable+ephemeral contract.
	lowerDir := filepath.Join(ctxDir, "lower")
	upperDir := filepath.Join(ctxDir, "upper")
	workDir := filepath.Join(ctxDir, "work")
	if err := os.MkdirAll(ctxDir, 0o755); err != nil {
		return 0, fmt.Errorf("mkdir %s: %w", ctxDir, err)
	}
	// unmountCtx unmounts the tmpfs at ctxDir; defined as a closure so
	// every error path below can clean up. Best-effort: a failed unmount
	// is logged, not fatal.
	unmountCtx := func() {
		if uerr := syscall.Unmount(ctxDir, 0); uerr != nil && !errors.Is(uerr, syscall.EINVAL) {
			fmt.Fprintf(os.Stderr, "voila: unmount tmpfs %s: %v\n", ctxDir, uerr)
		}
	}
	if err := syscall.Mount("tmpfs", ctxDir, "tmpfs", 0, ""); err != nil {
		_ = os.RemoveAll(ctxDir)
		return 0, fmt.Errorf("mount tmpfs %q: %w", ctxDir, err)
	}
	for _, d := range []string{rootfsDir, bundleDir, lowerDir, upperDir, workDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			unmountCtx()
			_ = os.RemoveAll(ctxDir)
			return 0, fmt.Errorf("mkdir %s: %w", d, err)
		}
	}

	// 1. Mount the merged root at lowerDir. Two backends:
	//   - "erofs": EROFS over NBD when the kernel has chunk-based EROFS
	//     (5.15+) and a free /dev/nbd* (auto, or VOILA_MOUNT_BACKEND=erofs).
	//   - "fuse": FUSE daemon over the merged manifest tree (fallback, or
	//     VOILA_MOUNT_BACKEND=fuse).
	// The overlay upper is stacked the same way regardless of backend.
	var unmountLower func()
	if mountBackend() == "erofs" {
		ero, err := mountErofs(ctx, store, spec.RootChunk, lowerDir)
		if err != nil {
			unmountCtx()
			_ = os.RemoveAll(ctxDir)
			return 0, fmt.Errorf("mount erofs lower %q: %w", lowerDir, err)
		}
		unmountLower = ero
	} else {
		tree, err := mount.Load(ctx, store, spec.RootChunk)
		if err != nil {
			unmountCtx()
			_ = os.RemoveAll(ctxDir)
			return 0, fmt.Errorf("load manifest tree: %w", err)
		}
		srv, err := mount.Mount(lowerDir, tree, store, mount.Options{AllowOther: true})
		if err != nil {
			unmountCtx()
			_ = os.RemoveAll(ctxDir)
			return 0, fmt.Errorf("mount lower %q: %w", lowerDir, err)
		}
		unmountLower = func() {
			if uerr := srv.Unmount(); uerr != nil {
				fmt.Fprintf(os.Stderr, "voila: unmount %s: %v\n", lowerDir, uerr)
			}
		}
	}

	// 2. Stack a writable overlay over the lower (FUSE or EROFS).
	// overlayfs gives copy-up semantics: reads come from the
	// content-addressed lower (chunks still lazy-fetched on first
	// touch), writes copy the affected file up to upperDir. The image
	// stays RO + content-addressed; the container gets a writable rootfs
	// for entrypoints that need it (postgres chmod'ing
	// /var/lib/postgresql/data, apt install, …). upper+work live on the
	// tmpfs at ctxDir and are removed with it on teardown, so nothing
	// persists across a run.
	overlayData := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lowerDir, upperDir, workDir)
	if err := syscall.Mount("overlay", rootfsDir, "overlay", 0, overlayData); err != nil {
		unmountLower()
		unmountCtx()
		_ = os.RemoveAll(ctxDir)
		return 0, fmt.Errorf("mount overlay %q: %w (lower=%s)", rootfsDir, err, lowerDir)
	}
	// unmountAll tears down the overlay first, then the lower, then
	// the tmpfs at ctxDir. The overlay must go before the lower: a busy
	// lower (still stacked under the overlay) makes the unmount fail
	// with EBUSY. The tmpfs goes last (it backs lower+upper+work+rootfs).
	// Best-effort on each layer; errors are logged, not fatal, so teardown
	// always proceeds.
	unmountAll := func() {
		if oerr := syscall.Unmount(rootfsDir, 0); oerr != nil && !errors.Is(oerr, syscall.EINVAL) {
			fmt.Fprintf(os.Stderr, "voila: unmount overlay %s: %v\n", rootfsDir, oerr)
		}
		unmountLower()
		unmountCtx()
	}

	// 3. Fetch + parse the OCI image config chunk for process defaults.
	cfgData, err := store.Get(ctx, spec.ConfigChunk)
	if err != nil {
		unmountAll()
		return 0, fmt.Errorf("read image config chunk: %w", err)
	}
	icfg, err := runtime.ParseImageConfig(cfgData)
	if err != nil {
		unmountAll()
		return 0, fmt.Errorf("parse image config: %w", err)
	}
	argv := icfg.Argv(spec.Args)
	if len(argv) == 0 {
		unmountAll()
		return 0, fmt.Errorf("image %q has no entrypoint/cmd and no args given", spec.Ref)
	}

	// 4. Build + write the OCI bundle. Writable: true flips Root.Readonly
	// off so runc mounts the overlay rootfs read-write.
	ocispec, err := runtime.BuildSpec(runtime.BundleOpts{
		RootfsPath:       rootfsDir,
		Args:             argv,
		Env:              icfg.Environ(),
		Cwd:              icfg.Cwd(),
		Writable:         true,
		MemoryLimitBytes: spec.MemoryLimitBytes,
		CPUQuotaPercent:  spec.CPUQuotaPercent,
	})
	if err != nil {
		unmountAll()
		return 0, fmt.Errorf("build spec: %w", err)
	}
	if err := runtime.WriteBundle(bundleDir, ocispec); err != nil {
		unmountAll()
		return 0, fmt.Errorf("write bundle: %w", err)
	}

	runner := runtime.NewRunc()

	// Register the launch state for Exec. Cleared in the teardown defer
	// below so an Exec concurrent with shutdown sees a consistent state.
	st := &launchState{
		cfg:         icfg,
		bundleDir:   bundleDir,
		rootfsDir:   rootfsDir,
		ctxDir:      ctxDir,
		rootChunk:   spec.RootChunk,
		configChunk: spec.ConfigChunk,
	}
	l.mu.Lock()
	l.states[spec.ID] = st
	l.mu.Unlock()

	// Teardown runs on all exit paths (success and failure). Order matches
	// run_linux.go: best-effort force delete, unmount, remove ctx dir.
	defer func() {
		l.mu.Lock()
		delete(l.states, spec.ID)
		l.mu.Unlock()
		if derr := runner.Delete(ctx, spec.ID, true); derr != nil && !isAlreadyGone(derr) {
			fmt.Fprintf(os.Stderr, "voila: delete %s: %v\n", spec.ID, derr)
		}
		unmountAll()
		_ = os.RemoveAll(ctxDir)
	}()

	// 4. Wire the IOSink into io.Writer adapters for the runc child.
	stdoutW := &sinkWriter{sink: sink, stderr: false}
	stderrW := &sinkWriter{sink: sink, stderr: true}

	// 5. Drive runc run in a goroutine; the foreground Run blocks until the
	// container exits. The sink.Started(pid) needs the pid which the
	// foreground Run does not expose, so we poll runner.State in parallel
	// until status == "running" (or the run returns, whichever first).
	codeCh := make(chan int, 1)
	errCh := make(chan error, 1)
	go func() {
		code, rerr := runner.Run(ctx, spec.ID, bundleDir, runtime.StdIO{
			In:  spec.Stdin,
			Out: stdoutW,
			Err: stderrW,
		})
		codeCh <- code
		errCh <- rerr
	}()

	// The container may exit before runc ever reports "running" (a fast
	// crash or an `echo`); the exit-code receive in this loop must be the
	// one that returns, or the post-loop receive would block forever on the
	// single-send channel.
	pidDeadline := time.NewTimer(30 * time.Second)
	defer pidDeadline.Stop()
	pidTicker := time.NewTicker(10 * time.Millisecond)
	defer pidTicker.Stop()
	for {
		select {
		case <-pidTicker.C:
			if st, serr := runner.State(ctx, spec.ID); serr == nil && st.Status == "running" {
				sink.Started(st.Pid)
				return awaitRun(codeCh, errCh)
			}
		case <-pidDeadline.C:
			// runc never reached running within the grace; fire started
			// with pid 0 so the FSM transitions to Running regardless (a
			// caller observing pid=0 may fall back to other discovery).
			sink.Started(0)
			return awaitRun(codeCh, errCh)
		case code := <-codeCh:
			// Exited before we ever observed "running"; do not fire Started
			// (the FSM moves Scheduled → Finished directly).
			return code, <-errCh
		}
	}
}

// awaitRun collects the foreground run's result once Started has been fired.
func awaitRun(codeCh <-chan int, errCh <-chan error) (int, error) {
	code := <-codeCh
	return code, <-errCh
}

// Exec drives `runc exec --process <tmpfile> <id>` for an additional process
// inside an already-running context. The process spec mirrors BuildSpec's
// defaults (caps/rlimits/no_new_privileges) via runtime.BuildProcess; env and
// cwd come from the context's parsed image config (recorded at Launch time).
func (l *platformLauncher) Exec(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error) {
	l.mu.Lock()
	st, ok := l.states[ctxID]
	l.mu.Unlock()
	if !ok {
		return 0, fmt.Errorf("no running context %q", ctxID)
	}
	if len(spec.Args) == 0 {
		return 0, fmt.Errorf("exec: args must be non-empty")
	}

	p := runtime.BuildProcess(spec.Args, st.cfg.Environ(), st.cfg.Cwd())
	stdoutW := &sinkWriter{sink: sink, stderr: false}
	stderrW := &sinkWriter{sink: sink, stderr: true}

	return runtime.ExecProcess(ctx, ctxID, st.bundleDir, p, runtime.StdIO{
		In:  spec.Stdin,
		Out: stdoutW,
		Err: stderrW,
	})
}

// Kill signals sig to the container init via `runc kill`.
func (l *platformLauncher) Kill(ctx context.Context, ctxID string, sig syscall.Signal) error {
	l.mu.Lock()
	_, ok := l.states[ctxID]
	l.mu.Unlock()
	if !ok {
		return fmt.Errorf("no running context %q", ctxID)
	}
	runner := runtime.NewRunc()
	return runner.Kill(ctx, ctxID, sig)
}

// ----- io.Writer adapter around IOSink -----

// sinkWriter adapts an IOSink into an io.Writer so runtime.StdIO (which
// takes io.Writer) can drive the same ring+stream plumbing the worker owns.
type sinkWriter struct {
	sink   IOSink
	stderr bool
}

// Write forwards p (whole or chunked by upstream io.Copy defaults) to the
// IOSink's Stdout/Stderr method. It never returns an error so a transient
// sink failure does not turn into a runc run failure.
func (w *sinkWriter) Write(p []byte) (int, error) {
	if w.stderr {
		w.sink.Stderr(p)
	} else {
		w.sink.Stdout(p)
	}
	return len(p), nil
}

// isAlreadyGone reports whether err is (likely) a "no such container" error
// from runc delete (mirrors cmd/voila/run_linux.go).
func isAlreadyGone(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "container not found") ||
		strings.Contains(msg, "no such container")
}

// Compile-time assertion that *platformLauncher satisfies Launcher.
var _ Launcher = (*platformLauncher)(nil)

// defaultPlatformLauncher returns the platform Launcher for Config on Linux
// (the daemon-owned mount+runc launcher). Mirrored on non-Linux by
// launch_stub.go's no-op stub.
func defaultPlatformLauncher(cfg Config) Launcher {
	return newPlatformLauncher(cfg.Root, cfg.Store)
}
