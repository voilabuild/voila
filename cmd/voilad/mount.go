// mount.go implements `voilad mount <ref-or-digest-prefix> <mountpoint>
// [-root dir] [-allow-other] [-registry URL]`: the debug FUSE mount (the old
// `voila mount` Linux-only path moved into the daemon binary). Flag parsing
// and image resolution are OS-independent; the actual FUSE mount lives in
// mount_linux.go (with a stub in mount_stub.go for non-Linux platforms).
//
// main short-circuits non-Linux builds before reaching here, but the stub
// keeps the package compilable everywhere.

package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/registry"
)

// cmdMount implements `voilad mount <ref-or-digest-prefix> <mountpoint>
// [-root dir] [-allow-other] [-registry URL]`. Flag parsing and image
// resolution are OS-independent; the actual FUSE mount lives in
// mount_linux.go (with a stub in mount_stub.go).
func cmdMount(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voilad", "mount", cfg.Stderr)
	var (
		rootFlag     string
		allowOther   bool
		registryFlag string
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.BoolVar(&allowOther, "allow-other", false, "allow non-root users to access the mount (adds allow_other + default_permissions)")
	fs.StringVar(&registryFlag, "registry", "", "registry URL for lazy chunk fetch + auto-pull (default: $VOILA_REGISTRY)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return errors.New("usage: voilad mount <ref-or-digest-prefix> <mountpoint> [-root dir] [-allow-other] [-registry URL]")
	}
	query := fs.Arg(0)
	mountpoint := fs.Arg(1)

	root := cli.ResolveRoot(rootFlag, cfg.Root)
	registryURL := resolveRegistry(registryFlag, root)
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	return runMount(cfg, out, root, query, mountpoint, allowOther, registryURL)
}

// runMount does the OS-independent part of the mount command: opens the chunk
// store and image store, resolves the image query, and hands off to the
// platform-specific mountAndServe helper.
//
// registryURL, when non-empty, enables two behaviors: on a local resolution
// miss the image manifest is auto-pulled from the registry (so `voilad mount
// <ref>` on an empty root Just Works), and the chunk store handed to the
// mount is wrapped in a CachedStore so chunk misses during the FUSE mount
// lazy-stream from the registry.
func runMount(cfg Config, out interface{ Write([]byte) (int, error) }, root, query, mountpoint string, allowOther bool, registryURL string) error {
	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	var registryClient *registry.Client
	if registryURL != "" {
		registryClient, err = registry.NewClient(registryURL, registry.WithToken(resolveRegistryToken(root)))
		if err != nil {
			return fmt.Errorf("registry client: %w", err)
		}
		defer registryClient.Close()
	}

	im, rootChunk, err := imagestore.Resolve(imgStore, query)
	if err != nil {
		if registryClient != nil {
			if im2, ok := imagestore.AutoPull(query, imgStore, asPuller(registryClient)); ok {
				im = im2
				rootChunk, err = imagestore.RootChunkFromManifest(im)
				if err != nil {
					return err
				}
			} else {
				return err
			}
		} else {
			return err
		}
	}

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return fmt.Errorf("open chunk store: %w", err)
	}
	defer store.Close()

	var chunkStore chunkstore.ChunkStore = store
	if registryClient != nil {
		chunkStore = chunkstore.NewCached(store, registryClient)
	}

	// Sanity-check the chunk exists before mounting to give a clear error
	// rather than a runtime EIO when the tree tries to fetch it. Only valid
	// with no registry configured: with one, a pulled (or auto-pulled)
	// manifest legitimately has remote-only chunks (Stat is local-only by
	// contract); the CachedStore lazy-fetches at mount/read time.
	if registryClient == nil {
		if _, ok := chunkStore.Stat(rootChunk); !ok {
			return fmt.Errorf("merged root manifest chunk %s not present in store (image ref %q)", rootChunk, im.GetImageRef())
		}
	}

	if err := mountAndServe(out, chunkStore, rootChunk, im.GetImageRef(), mountpoint, allowOther); err != nil {
		return err
	}
	return nil
}

// errLinuxOnly is returned by mount_stub on non-Linux to give a clear message.
var errLinuxOnly = errors.New("voilad mount requires linux (run inside the devcontainer)")

// signalsClosed installs a SIGINT/SIGTERM handler that returns a channel
// closed on either signal, so the mount loop can block until interrupted.
func signalsClosed() <-chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	return ch
}
