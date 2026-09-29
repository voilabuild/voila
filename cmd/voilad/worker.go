// worker.go implements voilad's default action: launch the voila gRPC daemon
// in the foreground. The daemon owns run contexts (the internal/worker.Worker)
// and serves the Worker gRPC service on a unix-domain socket under the voila
// root. SIGINT/SIGTERM trigger a graceful Shutdown (10s grace) and exit 0.
// The socket file is created freshly on each launch and removed on exit; a
// stale socket from a crashed previous daemon is detected by attempting a
// dial and removed.
//
// This is essentially cmd/voila's old cmd_worker.go moved as-is into the
// daemon binary. The resolve closure wired here mirrors what the old CLI
// assembled in run/mount/worker; here it is the single canonical resolver
// used by Run RPCs.

package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/worker"
)

// cmdWorker implements the default voilad action: `voilad [-root dir]
// [-socket path] [-registry URL]`. It builds a worker.Config bound to the
// voila root's chunk store + image store, listens on the worker socket
// (default /var/run/voila.sock), serves the Worker gRPC service, and blocks
// until the process receives SIGINT / SIGTERM, then performs a graceful
// Shutdown with a 10s timeout and exits 0. The socket file is removed on exit.
func cmdWorker(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voilad", "voilad", cfg.Stderr)
	var (
		rootFlag     string
		socketFlag   string
		registryFlag string
		traceFlag    bool
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	fs.StringVar(&registryFlag, "registry", "", "registry URL for lazy chunk fetch + auto-pull (default: $VOILA_REGISTRY)")
	fs.BoolVar(&traceFlag, "trace", false, "record a per-run chunk-access trace (JSONL) under <root>/traces/")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("usage: voilad [-root dir] [-socket path] [-registry URL] [-trace]")
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)
	registryURL := resolveRegistry(registryFlag, root)

	out := cfg.Stderr
	if out == nil {
		out = os.Stderr
	}

	// Detect a daemon already running: probe the socket; if a dial succeeds,
	// refuse; if the socket file exists but dialing fails, treat it as stale
	// (a previous crash left it behind) and remove the file before we listen.
	path := socket
	if _, err := os.Stat(path); err == nil {
		if cli.TryProbe(path) == nil {
			return fmt.Errorf("worker already running on %s", path)
		}
		// Stale socket — remove it so net.Listen does not fail with EADDRINUSE.
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove stale socket %s: %w", path, err)
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat %s: %w", path, err)
	}

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return fmt.Errorf("open chunk store: %w", err)
	}
	defer store.Close()

	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	// RegistryHub is updated at startup from <root>/registry.creds and live via
	// SetRegistry RPC when the CLI hands off creds. CachedStore always wraps
	// the local store so lazy fetch works once creds arrive.
	hub := worker.NewRegistryHub()
	token := resolveRegistryToken(root)
	if registryURL != "" {
		if err := hub.Configure(registryURL, token); err != nil {
			return fmt.Errorf("registry client: %w", err)
		}
	}
	chunkStore := chunkstore.NewCached(store, hub)

	// Access tracing: each run writes a JSONL trace (chunk Gets with
	// hit/miss + wait time + demand/prefetch source, plus exec/exit phase
	// markers) to <root>/traces/. Explore with jq/duckdb; no daemon
	// overhead when disabled.
	var traceDir string
	if traceFlag {
		traceDir = filepath.Join(root, "traces")
		if err := os.MkdirAll(traceDir, 0o755); err != nil {
			return fmt.Errorf("mkdir traces dir: %w", err)
		}
	}

	resolve := makeResolve(imgStore, chunkStore, hub)
	w := worker.NewWorker(worker.Config{
		Root:     root,
		Store:    chunkStore,
		Resolve:  resolve,
		TraceDir: traceDir,
		Registry: hub,
	})
	// Listen on the unix socket. Mkdir both the data root and the socket's
	// parent so a fresh / custom socket path works.
	if err := os.MkdirAll(root, 0o755); err != nil {
		return fmt.Errorf("mkdir root: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir socket dir: %w", err)
	}
	lis, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen %s: %w", path, err)
	}
	// Lock the socket down. Default: only the owning user can drive the daemon
	// (0600). A system daemon meant to be driven by non-root users (e.g. the
	// install.sh systemd unit) sets VOILA_SOCKET_GROUP (a group name) and
	// VOILA_SOCKET_MODE (e.g. 0660) so members of the group can dial it; the
	// chown is best-effort (needs root, ignored if it fails) so a non-root
	// `voilad` still starts — it just keeps the 0600 default.
	if g := os.Getenv("VOILA_SOCKET_GROUP"); g != "" {
		if grp, err := user.LookupGroup(g); err == nil {
			if gid, err := strconv.Atoi(grp.Gid); err == nil {
				_ = os.Chown(path, -1, gid)
			}
		}
	}
	mode := 0o600
	if m := os.Getenv("VOILA_SOCKET_MODE"); m != "" {
		if parsed, err := strconv.ParseUint(m, 8, 32); err == nil {
			mode = int(parsed)
		}
	}
	if err := os.Chmod(path, os.FileMode(mode)); err != nil {
		_ = lis.Close()
		return fmt.Errorf("chmod %s: %w", path, err)
	}
	fmt.Fprintf(out, "worker listening on %s\n", path)
	fmt.Fprintf(out, "mount backend: %s (%s)\n", worker.MountBackend(), worker.MountBackendReason())
	if traceDir != "" {
		fmt.Fprintf(out, "tracing: %s\n", traceDir)
	}

	// Best-effort cleanup of the socket file on exit. Removed in the
	// graceful path below, but the defer is a belt-and-suspenders for a
	// hard-Stop escalation that exits the process without closing cleanly.
	defer func() { _ = os.Remove(path) }()

	// Signal handling: SIGINT / SIGTERM → graceful Shutdown with a 10s
	// timeout, then exit 0.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	serveErr := make(chan error, 1)
	go func() { serveErr <- w.Serve(lis) }()

	select {
	case sig := <-sigCh:
		fmt.Fprintf(out, "voilad: caught %v, shutting down\n", sig)
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		w.Shutdown(shutdownCtx)
		cancel()
		_ = os.Remove(path)
		return nil
	case err := <-serveErr:
		// Serve returns when the listener is closed or the server stops.
		_ = os.Remove(path)
		return fmt.Errorf("serve: %w", err)
	}
}

// makeResolve builds the worker.Config.Resolve closure for cmdWorker from an
// open imagestore.Store + chunk store + a registry hub. It mirrors the
// cmd-side resolve: imagestore.Resolve finds the manifest, then the resolved
// root + config chunk ids are returned (verified locally when no registry is
// configured); auto-pull is wired when the hub has a client. The image totals
// (ImageChunks / ImageBytes) come from the images.db row so the post-run
// fetch stats line can render "<pct> of N chunks". A missing row falls back to
// 0/0 (the stats line omits the parenthetical in that case).
func makeResolve(imgStore *imagestore.Store, store chunkstore.ChunkStore, hub *worker.RegistryHub) func(query string) (worker.ResolvedImage, error) {
	return func(query string) (worker.ResolvedImage, error) {
		registryClient := hub.Client()
		puller := asPuller(registryClient)
		im, rootChunk, err := imagestore.Resolve(imgStore, query)
		if err != nil {
			if registryClient != nil {
				if im2, ok := imagestore.AutoPull(query, imgStore, puller); ok {
					im = im2
					rootChunk, err = imagestore.RootChunkFromManifest(im)
					if err != nil {
						return worker.ResolvedImage{}, err
					}
				} else {
					return worker.ResolvedImage{}, err
				}
			} else {
				return worker.ResolvedImage{}, err
			}
		}
		if len(im.GetConfigChunk()) != len(chunkstore.ChunkID{}) {
			return worker.ResolvedImage{}, fmt.Errorf("image %q: config chunk is not 32 bytes", im.GetImageRef())
		}
		var cfgChunkID chunkstore.ChunkID
		copy(cfgChunkID[:], im.GetConfigChunk())
		// Sanity-check the chunks exist locally before handing them to the
		// launcher — but ONLY when no registry is configured. With a registry,
		// a manifest obtained via `voila pull` OR auto-pull legitimately has
		// all chunks remote until first touch; Stat is local-only by the
		// interface contract, and the CachedStore lazy-fetches at Get time.
		if registryClient == nil {
			if _, ok := store.Stat(cfgChunkID); !ok {
				return worker.ResolvedImage{}, fmt.Errorf("image %q: config chunk %s not in store", im.GetImageRef(), cfgChunkID)
			}
			if _, ok := store.Stat(rootChunk); !ok {
				return worker.ResolvedImage{}, fmt.Errorf("image %q: merged root manifest chunk %s not in store", im.GetImageRef(), rootChunk)
			}
		}
		resolved := worker.ResolvedImage{
			Ref:         im.GetImageRef(),
			RootChunk:   rootChunk,
			ConfigChunk: cfgChunkID,
		}
		// Pull the ingest-time totals (chunk_count, total_size) from the
		// images.db row keyed by the resolved ref. A missing row leaves
		// the totals at 0 (caller renders the stats line without the
		// parenthetical).
		if rec, ok := imgStore.LookupRef(im.GetImageRef()); ok {
			if rec.ChunkCount > 0 {
				resolved.ImageChunks = uint64(rec.ChunkCount)
			}
			if rec.TotalSize > 0 {
				resolved.ImageBytes = uint64(rec.TotalSize)
			}
		}
		return resolved, nil
	}
}
