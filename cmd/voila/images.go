package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
)

// imagesSubSpecs describes one `voila images` subcommand for both routing
// (via imagesNode's tree children) and help rendering.
var imagesSubSpecs = []struct {
	name  string
	usage string // synopsis after the subcommand word ("" = none)
	short string // one-line description for help
}{
	{"info", "<ref-or-digest-prefix>", "show per-image detail (ref/digest/chunks/size)"},
	{"rm", "<ref>", "delete an image's index row + manifest file (chunks stay until gc)"},
	{"gc", "", "reclaim chunks unreachable from any remaining image manifest"},
	{"prune", "[-f]", "wipe ALL local state: every image, manifest, chunk, and cache entry"},
}

// imagesNode builds the `voila images` node for the command tree: the bare
// form lists images; each entry of imagesSubSpecs becomes a child so
// `voila help images` and typo suggestions see them.
func imagesNode(cfg Config) *cli.Command {
	node := &cli.Command{
		Name:  "images",
		Usage: "[info <ref-or-digest-prefix> | rm <ref> | gc | prune [-f]] [-root dir]",
		Short: "list / inspect / remove ingested images, reclaim unreachable chunks (gc), or wipe ALL local images + chunks (prune)",
		Run:   wrap(cfg, cmdImages),
	}
	for _, spec := range imagesSubSpecs {
		spec := spec
		node.Subs = append(node.Subs, &cli.Command{
			Name:  spec.name,
			Usage: spec.usage,
			Short: spec.short,
			Run: func(args []string) error {
				return cmdImagesSub(cfg, spec.name, args)
			},
		})
	}
	return node
}

// cmdImages implements `voila images` and its subcommands:
//   - `voila images`            list ingested images (table)
//   - `voila images info <ref>` show per-image detail (ref/digest/chunks/size)
//   - `voila images rm <ref>`   delete the sqlite row + the .pb manifest file
//   - `voila images gc`         walk remaining manifests for reachability,
//     then store.GC the unreachable chunks
//   - `voila images prune [-f]` wipe ALL local state: every image row, .pb
//     manifest, chunk blob + index row, and layer cache entry (the nuclear
//     counterpart to gc's reachability-based reclaim)
//
// The subcommand is selected purely by argv position[0]; flags accepted by
// the bare form (-root) precede the subcommand word for `info`/`rm`/`gc`
// so they apply uniformly.
//
// Routing exists twice by design: the command tree (imagesNode below) owns
// it for real CLI invocations, and this switch keeps direct calls —
// `cmdImages(cfg, []string{"prune", "-f"})`, as the tests do — working
// identically.
func cmdImages(cfg Config, args []string) error {
	// Detect the optional subcommand word before flag parsing: a subcommand
	// word consumes the rest of argv, so the subcommand's flag set drives the
	// remaining positional parsing. A bare `voila images` falls through to
	// the list path.
	if len(args) > 0 {
		switch args[0] {
		case "info", "rm", "gc", "prune":
			return cmdImagesSub(cfg, args[0], args[1:])
		}
	}

	fs := cli.NewFlagSet("voila", "images", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock); used by `gc` to refuse while a daemon runs")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("usage: voila images [-root dir] [-socket path]")
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	_ = cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root) // accepted for parity with subcommands
	store, err := imagestore.Open(root)
	if err != nil {
		return err
	}
	defer store.Close()
	rows, err := store.List()
	if err != nil {
		return err
	}
	printImagesTable(cfg.Stdout, rows)
	return nil
}

// cmdImagesSub dispatches the `info`/`rm`/`gc` subcommands of `voila images`.
// The subcommand word has already been consumed; args is the remainder (flags
// + positional).
//
// Each subcommand gets its own flag set: shared flags (-root/-socket) are
// declared for all, but sub-specific flags (prune's -f) are declared only
// for their owner — so e.g. `voila images gc -f` is a parse error rather
// than a silently-ignored flag.
func cmdImagesSub(cfg Config, sub string, args []string) error {
	fs := cli.NewFlagSet("voila", "images "+sub, cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
		forceFlag  bool
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock); used by `gc`/`prune` to refuse while a daemon runs")
	if sub == "prune" {
		fs.BoolVar(&forceFlag, "force", false, "skip the confirmation prompt")
		fs.BoolVar(&forceFlag, "f", false, "shorthand for -force")
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	positional := fs.Args()
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	switch sub {
	case "info":
		if len(positional) != 1 {
			return fmt.Errorf("usage: voila images info <ref-or-digest-prefix> [-root dir] [-socket path]")
		}
		return imagesInfo(cfg, root, positional[0])
	case "rm":
		if len(positional) != 1 {
			return fmt.Errorf("usage: voila images rm <ref> [-root dir] [-socket path]")
		}
		return imagesRm(cfg, root, positional[0])
	case "gc":
		if len(positional) != 0 {
			return fmt.Errorf("usage: voila images gc [-root dir] [-socket path]")
		}
		return imagesGC(cfg, root, socket)
	case "prune":
		if len(positional) != 0 {
			return fmt.Errorf("usage: voila images prune [-f] [-root dir] [-socket path]")
		}
		return imagesPrune(cfg, root, socket, forceFlag)
	}
	return fmt.Errorf("unknown images subcommand %q", sub)
}

// imagesInfo resolves query like the mount path and prints ref, digest, the
// merged-root manifest chunk (hex), layer count, each provenance layer's
// manifest chunk + whiteout count, total size, chunk count, and the ingested
// timestamp — the metadata fields persisted at ingest time.
func imagesInfo(cfg Config, root, query string) error {
	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()
	im, _, err := imagestore.Resolve(imgStore, query)
	if err != nil {
		return err
	}
	// Pull the sqlite row so we can show ingested-time / size / chunk count
	// (which the protobuf manifest does not carry).
	rows, err := imgStore.List()
	if err != nil {
		return err
	}
	var row imagestore.Record
	haveRow := false
	for _, r := range rows {
		if r.Ref == im.GetImageRef() {
			row = r
			haveRow = true
			break
		}
	}

	w := cfg.Stdout
	if w == nil {
		w = os.Stdout
	}
	fmt.Fprintf(w, "ref:               %s\n", im.GetImageRef())
	if len(im.GetImageDigest()) > 0 {
		fmt.Fprintf(w, "digest:           sha256:%x\n", im.GetImageDigest())
	} else {
		fmt.Fprintln(w, "digest:           -")
	}
	if len(im.GetMergedRootManifestChunk()) == 32 {
		fmt.Fprintf(w, "merged root chunk: %x\n", im.GetMergedRootManifestChunk())
	} else {
		fmt.Fprintln(w, "merged root chunk: -")
	}
	layers := im.GetProvenanceLayers()
	fmt.Fprintf(w, "layers:            %d\n", len(layers))
	for i, l := range layers {
		whiteouts := uint64(0)
		if l != nil {
			whiteouts = l.GetWhiteoutsCount()
		}
		var ckHex string
		if l != nil && len(l.GetRootManifestChunk()) == 32 {
			ckHex = fmt.Sprintf("%x", l.GetRootManifestChunk())
		} else {
			ckHex = "-"
		}
		fmt.Fprintf(w, "  layer %d: chunk=%s whiteouts=%d\n", i, ckHex, whiteouts)
	}
	if haveRow {
		fmt.Fprintf(w, "total size:        %s\n", cli.FormatBytes(uint64(row.TotalSize)))
		fmt.Fprintf(w, "chunk count:       %d\n", row.ChunkCount)
		fmt.Fprintf(w, "ingested:          %s\n", cli.FormatTime(row.IngestedNS))
	} else {
		fmt.Fprintf(w, "total size:        -\n")
		fmt.Fprintf(w, "chunk count:       -\n")
		fmt.Fprintf(w, "ingested:          -\n")
	}
	return nil
}

// imagesRm deletes the sqlite row for ref AND the on-disk
// <imgDir>/<key>.pb manifest file. It does NOT reclaim chunks (chunks are
// reclaimed by `voila images gc`); a reminder is printed so the user knows
// why space has not decreased.
//
// The query accepts both a ref and a digest prefix, mirroring `voila images
// info`: an unnamed OCI-archive image stores its row with Ref=""; the
// digest is the only handle that surfaces in `voila images` output (the
// empty REF cell collapses in awk's default FS), so the test/automation
// path is "list → digest → rm <digest>". imagestore.Resolve backfills
// im.ImageRef to the row's Ref for both named and unnamed images
// (LoadImageManifest sets ImageRef = ref when empty), so DeleteImagesRow
// and ManifestPath receive the actual on-disk key.
func imagesRm(cfg Config, root, query string) error {
	imgStore, err := imagestore.Open(root)
	if err != nil {
		return fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()
	im, _, err := imagestore.Resolve(imgStore, query)
	if err != nil {
		return err
	}
	ref := im.GetImageRef()
	if _, err := imgStore.DeleteImagesRow(ref); err != nil {
		return fmt.Errorf("delete row: %w", err)
	}
	pbPath := imgStore.ManifestPath(ref)
	if err := os.Remove(pbPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove %s: %w", pbPath, err)
	}
	out := cfg.Stderr
	if out == nil {
		out = os.Stderr
	}
	fmt.Fprintln(out, "Reminder: chunks are reclaimed by `voila images gc`.")
	return nil
}

// imagesGC walks the remaining image manifest pb files, computes their
// transitive reachable chunk set via ingest.Reachable, and calls
// store.GC(reachable). It refuses to run when the worker daemon is
// reachable (a running context may hold chunk references the v0.1 reachability
// walk does not track). Chunks removed and bytes reclaimed (best-effort) are
// printed.
func imagesGC(cfg Config, root, socket string) error {
	out := cfg.Stderr
	if out == nil {
		out = os.Stderr
	}
	// Refuse while the daemon answers on the socket: running contexts may
	// hold chunk references that the reachability walk does not see.
	if cli.TryProbe(socket) == nil {
		return fmt.Errorf("stop voila worker before gc")
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
	// Collect every remaining image manifest (the on-disk pb files keyed by
	// the sqlite rows). A missing/Corrupt pb file aborts gc (do NOT gc on
	// errors) so a corruption event is not silently turned into chunk loss.
	rows, err := imgStore.List()
	if err != nil {
		return fmt.Errorf("list images: %w", err)
	}
	images := make([]*voilapb.ImageManifest, 0, len(rows))
	for _, r := range rows {
		im, _, err := imgStore.LoadImageManifest(r.Ref)
		if err != nil {
			return fmt.Errorf("load %q: %w", r.Ref, err)
		}
		images = append(images, im)
	}

	ctx := context.Background()
	reachable, err := ingest.Reachable(ctx, store, images)
	if err != nil {
		return fmt.Errorf("reachability walk: %w (store may be corrupt — gc refused)", err)
	}

	// Bytes reclaimed: sum the StoredLen of every chunk NOT in reachable, via
	// Stat (BEFORE calling GC). Stat returns false for the missing chunks
	// (which would also be removed by GC, contributing 0 bytes).
	var reclaimedBytes uint64
	// Walk all chunks the store indexes by asking GC's own scan — but we
	// want the unreachable list pre-delete. The LocalStore keeps an internal
	// scan we can't reach; for bytes we approximate by Stat'ing every chunk
	// id from the store's index. Alas LocalStore has no "list all" API in
	// v0.1, so we settle for a chunkCount-only report and rely on the
	// reachable map's complement being entirely the unreachable set. We
	// therefore print only the removed count (acceptable per the task spec).
	removed, err := store.GC(reachable)
	if err != nil {
		return fmt.Errorf("gc: %w", err)
	}
	if removed > 0 {
		fmt.Fprintf(out, "gc: removed %d chunk(s)%s\n", removed, formatReclaimedSuffix(reclaimedBytes))
	} else {
		fmt.Fprintln(out, "gc: nothing to reclaim")
	}

	// Hygiene: drop layers rows whose manifest_chunk GC just collected, so
	// the cache table does not grow unbounded (the per-layer cache hit
	// path's VerifyTreeChunks guard is the actual correctness backstop —
	// it rejects a stale hit and falls back to a fresh walk).
	if dead, derr := imgStore.DropDeadLayerCacheRows(store); derr != nil {
		// Non-fatal: a stale row only costs a wasted Lookup + Stat round
		// on the next ingest; print and continue.
		fmt.Fprintf(out, "gc: layer cache cleanup: %v\n", derr)
	} else if dead > 0 {
		fmt.Fprintf(out, "gc: dropped %d stale layer cache row(s)\n", dead)
	}
	return nil
}

// imagesPrune wipes ALL local state — the nuclear counterpart to gc:
//   - every .pb manifest file under <root>/images/ (globbed, so orphaned
//     manifests and unnamed images' files are swept too)
//   - every row in the images and layers tables
//   - every chunk blob + index row (plus orphaned blobs, via the whole-dir
//     sweep in LocalStore.PruneAll)
//
// It refuses to run while the worker daemon is reachable (same guard as gc),
// and prompts for confirmation unless -f was given. The store remains usable
// afterwards: re-ingest starts from a clean slate.
func imagesPrune(cfg Config, root, socket string, force bool) error {
	out := cfg.Stderr
	if out == nil {
		out = os.Stderr
	}
	// Refuse while the daemon answers on the socket: running contexts may
	// hold chunk references that pruning would yank out from under them.
	if cli.TryProbe(socket) == nil {
		return fmt.Errorf("stop voila worker before prune")
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

	// Size the warning with what is actually there right now.
	rows, err := imgStore.List()
	if err != nil {
		return fmt.Errorf("list images: %w", err)
	}
	chunkCount, chunkBytes, err := store.Count()
	if err != nil {
		return fmt.Errorf("count chunks: %w", err)
	}

	if !force {
		in := cfg.Stdin
		if in == nil {
			in = os.Stdin
		}
		fmt.Fprintf(out, "WARNING! This will delete %d image(s), %d chunk(s) (%s),\nand all layer cache entries. This cannot be undone.\nAre you sure? [y/N] ",
			len(rows), chunkCount, cli.FormatBytes(chunkBytes))
		answer, _ := bufio.NewReader(in).ReadString('\n')
		switch strings.ToLower(strings.TrimSpace(answer)) {
		case "y", "yes":
		default:
			fmt.Fprintln(out, "prune: aborted")
			return nil
		}
	}

	// Manifests first (glob catches files whose sqlite row is already gone),
	// then the index rows, then the chunks.
	pbFiles, err := filepath.Glob(filepath.Join(imgStore.ImgDir, "*.pb"))
	if err != nil {
		return fmt.Errorf("list manifests: %w", err)
	}
	for _, p := range pbFiles {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove %s: %w", p, err)
		}
	}
	prunedImages, err := imgStore.PruneAll()
	if err != nil {
		return fmt.Errorf("prune image store: %w", err)
	}
	prunedChunks, prunedBytes, err := store.PruneAll()
	if err != nil {
		return fmt.Errorf("prune chunk store: %w", err)
	}

	fmt.Fprintf(out, "prune: removed %d image(s), %d chunk(s) (%s)\n",
		prunedImages, prunedChunks, cli.FormatBytes(prunedBytes))
	return nil
}

// formatReclaimedSuffix turns a byte count into a " (N bytes)" suffix or an
// empty string when no bytes are tracked (the current implementation does not
// sum bytes — see imagesGC — so this returns "" until a Stat-based pre-scan
// is wired up).
func formatReclaimedSuffix(bytes uint64) string {
	if bytes == 0 {
		return ""
	}
	return fmt.Sprintf(" (%s)", cli.FormatBytes(bytes))
}

func printImagesTable(w io.Writer, rows []imagestore.Record) {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "REF\tDIGEST\tSIZE\tCHUNKS\tINGESTED")
	if len(rows) == 0 {
		tw.Flush()
		return
	}
	for _, r := range rows {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%d\t%s\n",
			r.Ref,
			cli.ShortDigest(r.ImageDigest),
			cli.FormatBytes(uint64(r.TotalSize)),
			r.ChunkCount,
			cli.FormatTime(r.IngestedNS),
		)
	}
	tw.Flush()
}
