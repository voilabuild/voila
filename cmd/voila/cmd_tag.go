// cmd_tag.go implements `voila tag <src> <new-ref> [-root dir]`: retags a
// locally ingested image without re-downloading or re-ingesting. It resolves
// <src> (ref or digest prefix) to its ImageManifest, rewrites the manifest's
// image_ref to <new-ref>, writes the manifest under the new ref key, and
// upserts a new sqlite row keyed by <new-ref> (same digest / chunks / size).
//
// The chunk closure is unchanged — a tag is just a new handle onto the same
// content — so `voila push <new-ref>` uploads the same chunks and publishes
// the manifest under <new-ref>. This is what lets you push an imported image
// under your registry org namespace (e.g. `voila tag python:3.13 myorg/python:3.13`).

package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"voila/internal/cli"
	"voila/internal/imagestore"
	voilapb "voila/internal/proto"
)

// cmdTag implements `voila tag <src> <new-ref> [-root dir]`.
func cmdTag(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "tag", cfg.Stderr)
	var rootFlag string
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return errors.New("usage: voila tag <src-ref-or-digest-prefix> <new-ref> [-root dir]")
	}
	src, newRef := fs.Arg(0), fs.Arg(1)
	root := cli.ResolveRoot(rootFlag, cfg.Root)

	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	im, _, err := imagestore.Resolve(imgStore, src)
	if err != nil {
		return err
	}
	srcRef := im.GetImageRef()

	if err := writeTag(imgStore, im, newRef); err != nil {
		return err
	}

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	fmt.Fprintf(out, "tagged %s -> %s\n", srcRef, newRef)
	return nil
}

// writeTag persists im under newRef: the manifest pb is rewritten with
// image_ref = newRef and a new sqlite row is upserted (same digest / chunks /
// size). Shared by `voila tag` and the `-push` tail of `voila import`. The
// source ref's own manifest file is left untouched.
func writeTag(imgStore *imagestore.Store, im *voilapb.ImageManifest, newRef string) error {
	im.ImageRef = newRef
	if err := imgStore.WriteManifestPB(newRef, im); err != nil {
		return fmt.Errorf("write manifest: %w", err)
	}

	now := time.Now().UnixNano()
	rec := imagestore.Record{
		Ref:                newRef,
		ImageDigest:        im.GetImageDigest(),
		MergedRootManifest: im.GetMergedRootManifestChunk(),
		TotalSize:          int64(im.GetTotalSize()),
		ChunkCount:         int64(im.GetChunkCount()),
		IngestedNS:         now,
		LastUsedNS:         now,
	}
	if err := imgStore.Upsert(rec); err != nil {
		return fmt.Errorf("upsert image row: %w", err)
	}
	return nil
}
