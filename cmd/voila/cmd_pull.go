// cmd_pull.go implements `voila pull <ref> [-registry URL] [-root dir]`:
// GET the ImageManifest from the registry, write it under <root>/images/
// (reusing imagestore.Store.WriteManifestPB) and upsert the images.db row
// (totals from manifest fields 6/7). NO chunks are downloaded — the
// lazy-streaming point of Phase 1: the manifest is a few KB, and `voila run
// <ref>` streams the chunks on demand via the CachedStore. Print line:
//
//	pulled <ref> (manifest only; chunks stream on demand)

package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/registry"
)

// cmdPull implements `voila pull <ref> [-registry URL] [-root dir]`.
func cmdPull(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "pull", cfg.Stderr)
	var (
		registryFlag string
		rootFlag     string
	)
	fs.StringVar(&registryFlag, "registry", "", "registry URL (default: $VOILA_REGISTRY; required to pull)")
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila pull <ref> [-registry URL] [-root dir]")
	}
	ref := fs.Arg(0)
	url := resolveRegistry(registryFlag)
	if url == "" {
		return errors.New("no registry configured: run `voila login` or set -registry / $VOILA_REGISTRY")
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	if err := handoffRegistryCreds(cfg, rootFlag, ""); err != nil {
		return fmt.Errorf("registry handoff: %w", err)
	}

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}

	if err := os.MkdirAll(root, 0o755); err != nil {
		return fmt.Errorf("mkdir root: %w", err)
	}

	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	client, err := registry.NewClient(url, registry.WithToken(resolveRegistryToken()))
	if err != nil {
		return fmt.Errorf("registry client: %w", err)
	}
	defer client.Close()

	ctx := context.Background()
	im, err := imagestore.PullManifest(ctx, imgStore, registryPuller{client}, ref)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "pulled %s (manifest only; chunks stream on demand)\n", im.GetImageRef())
	return nil
}
