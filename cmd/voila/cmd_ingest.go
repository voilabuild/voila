package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
)

// cmdIngest implements `voila ingest <tarball> [-ref override] [-platform os/arch] [-root dir]`.
func cmdIngest(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "ingest", cfg.Stderr)
	var (
		refFlag      string
		platformFlag string
		rootFlag     string
	)
	fs.StringVar(&refFlag, "ref", "", "override image ref (default: ref from tarball metadata)")
	fs.StringVar(&platformFlag, "platform", "", "select platform os/arch for multi-platform OCI indexes")
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila ingest <tarball> [-ref override] [-platform os/arch] [-root dir]")
	}
	tarball := fs.Arg(0)
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	return runIngest(cfg, root, tarball, refFlag, platformFlag)
}

// runIngest is the factored body of the ingest subcommand; tests call it
// directly with a temporary root.
func runIngest(cfg Config, root, tarball, refOverride, platform string) error {
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}

	if _, err := os.Stat(tarball); err != nil {
		return fmt.Errorf("stat tarball: %w", err)
	}

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return fmt.Errorf("open chunk store: %w", err)
	}
	defer store.Close()

	// Open the image store first so Ingest can use it as the per-layer
	// manifest cache (ingest.LayerCache): OCI-layout layers with a known blob
	// digest hit the cache and skip the tar walk; legacy docker-save layers
	// carry no digest and bypass the cache (Lookup and Store both skipped).
	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	ctx := context.Background()
	opts := ingest.Options{
		Platform:   platform,
		Ref:        refOverride,
		LayerCache: imgStore,
	}
	res, err := ingest.Ingest(ctx, tarball, store, opts)
	if err != nil {
		return fmt.Errorf("ingest: %w", err)
	}

	im := buildImageManifest(res)
	if err := imgStore.WriteManifestPB(res.Ref, im); err != nil {
		return fmt.Errorf("write image manifest: %w", err)
	}

	now := time.Now().UnixNano()
	rec := imagestore.Record{
		Ref:                res.Ref,
		ImageDigest:        res.ImageDigest,
		MergedRootManifest: res.MergedRootManifestChunk[:],
		TotalSize:          int64(res.BytesIn),
		ChunkCount:         int64(res.ChunkCount),
		IngestedNS:         now,
		LastUsedNS:         now,
	}
	if err := imgStore.Upsert(rec); err != nil {
		return err
	}

	onDisk, err := dirSize(root)
	if err != nil {
		// Non-fatal: report zero rather than failing the whole ingest.
		onDisk = 0
	}
	printIngestSummary(out, res, onDisk)
	return nil
}

// buildImageManifest assembles the persisted ImageManifest protobuf from an
// ingest Result.
func buildImageManifest(res *ingest.Result) *voilapb.ImageManifest {
	layers := make([]*voilapb.Layer, 0, len(res.Layers))
	for _, l := range res.Layers {
		layers = append(layers, &voilapb.Layer{
			RootManifestChunk: l.RootManifestChunk[:],
			WhiteoutsCount:    l.WhiteoutsCount,
		})
	}
	return &voilapb.ImageManifest{
		ImageRef:                res.Ref,
		ImageDigest:             res.ImageDigest,
		ConfigChunk:             res.ConfigChunk[:],
		MergedRootManifestChunk: res.MergedRootManifestChunk[:],
		ProvenanceLayers:        layers,
		TotalSize:               res.BytesIn,
		ChunkCount:              res.ChunkCount,
	}
}

// printIngestSummary writes the human-readable summary described in plan §5.7.
func printIngestSummary(w io.Writer, res *ingest.Result, onDisk uint64) {
	totalPutsN := res.ChunkCount + res.ChunksDeduped
	dedupRatio := ratioPct(res.ChunksDeduped, totalPutsN)
	compDedupRatio := ratioPct(res.StoredBytes, res.BytesIn)

	fmt.Fprintln(w, "ingest summary")
	fmt.Fprintf(w, "  image ref:        %s\n", refOrUnnamed(res.Ref))
	if len(res.ImageDigest) > 0 {
		fmt.Fprintf(w, "  image digest:    sha256:%x\n", res.ImageDigest)
	} else {
		fmt.Fprintln(w, "  image digest:    -")
	}
	fmt.Fprintf(w, "  layers:           %d\n", len(res.Layers))
	fmt.Fprintf(w, "  bytes in:         %s\n", cli.FormatBytes(res.BytesIn))
	fmt.Fprintf(w, "  chunks stored:    %d\n", res.ChunkCount)
	fmt.Fprintf(w, "  chunks deduped:   %d (%s of puts)\n", res.ChunksDeduped, dedupRatio)
	fmt.Fprintf(w, "  stored bytes:     %s (%s of bytes in)\n", cli.FormatBytes(res.StoredBytes), compDedupRatio)
	if totalLayers := uint64(len(res.Layers)); totalLayers > 0 {
		fmt.Fprintf(w, "  layers reused:   %d/%d\n", res.LayersReused, totalLayers)
	}
	fmt.Fprintf(w, "  on-disk footprint:%s\n", cli.FormatBytes(onDisk))
}

func refOrUnnamed(ref string) string {
	if ref == "" {
		return "(unnamed)"
	}
	return ref
}

func ratioPct(num, den uint64) string {
	if den == 0 {
		return "0%"
	}
	return strconv.FormatFloat(float64(num)/float64(den)*100, 'f', 2, 64) + "%"
}

// dirSize sums the sizes of all regular files under root recursively.
func dirSize(root string) (uint64, error) {
	var total uint64
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			// Best-effort: skip unreadable entries rather than aborting.
			return nil
		}
		if info.Mode().IsRegular() {
			total += uint64(info.Size())
		}
		return nil
	})
	return total, err
}
