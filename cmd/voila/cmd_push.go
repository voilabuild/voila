// cmd_push.go implements `voila push <ref-or-digest-prefix> [-registry URL]
// [-root dir]`: resolves the image locally, computes the chunk closure for
// JUST this image via ingest.Reachable, negotiates the set the registry is
// missing via ONE POST /v1/chunks/missing call (batched by the client at
// 16k ids/request — the v0.2 bulk-stat path), PUTs the missing chunks
// (concurrency 8, fail-fast), then PUTs the ImageManifest. The print line is
// "pushed <ref>: N chunks uploaded, M already present, X MiB".
//
// Push does NOT upload chunks that the registry already holds — the registry
// is the dedup boundary across separate voila roots. The closure walk uses
// ingest.Reachable against the LOCAL store, so the local root must hold
// every reachable chunk (it does, right after an ingest).
//
// Fall back: when the registry answers 404 on /v1/chunks/missing (an older
// registry that predates the bulk-stat endpoint), push falls back to the
// per-chunk HEAD negotiation path. One probe request decides the path; the
// fallback code path is intentionally small.

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/cli/progress"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"
	"voila/internal/registry"
)

// defaultPushConcurrency is the per-request worker fan-out used when the
// -concurrency flag and $VOILA_PUSH_CONCURRENCY are both unset. 64 is high
// enough to saturate a typical WAN link (the previous fixed value of 8 left
// bandwidth on the table on high-RTT links); with HTTP/2 (see
// registry.NewClient) the 64 streams multiplex on a single TCP+TLS
// connection, and with HTTP/1.1 the client's tuned Transport pools up to
// defaultMaxIdleConnsPerHost idle connections so 64 workers do not re-dial.
// The server-side LocalStore writer mutex is the upper bound on useful
// concurrency for the index write, but the per-chunk network RTT dominates
// the critical path so 64 in-flight PUTs still helps there.
const defaultPushConcurrency = 64

// minPushConcurrency / maxPushConcurrency bound the -concurrency flag so a
// typo cannot starve the upload (0/1) or open a goroutine storm (1e6).
const (
	minPushConcurrency = 1
	maxPushConcurrency = 1024
)

// cmdPush implements `voila push <ref-or-digest-prefix> [-registry URL]
// [-root dir]`.
func cmdPush(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "push", cfg.Stderr)
	var (
		registryFlag    string
		rootFlag        string
		concurrencyFlag int
	)
	fs.StringVar(&registryFlag, "registry", "", "registry URL (default: $VOILA_REGISTRY; required to push)")
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.IntVar(&concurrencyFlag, "concurrency", defaultPushConcurrency, "concurrent chunk uploads (default: $VOILA_PUSH_CONCURRENCY or 64)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila push <ref-or-digest-prefix> [-registry URL] [-root dir] [-concurrency N]")
	}
	query := fs.Arg(0)
	url := resolveRegistry(registryFlag)
	if url == "" {
		return errors.New("no registry configured: run `voila login` or set -registry / $VOILA_REGISTRY")
	}
	concurrency := resolvePushConcurrency(concurrencyFlag)
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	if err := handoffRegistryCreds(cfg, rootFlag, ""); err != nil {
		return fmt.Errorf("registry handoff: %w", err)
	}

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}
	return runPush(out, errOut, root, query, url, concurrency)
}

// runPush is the factored publish path shared by `voila push` and the
// `-push` tail of `voila import`: opens the stores under root, resolves
// query to a local image, negotiates + uploads missing chunks and PUTs the
// manifest under its image_ref. url must be non-empty.
func runPush(out, errOut io.Writer, root, query, url string, concurrency int) error {
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

	im, _, err := imagestore.Resolve(imgStore, query)
	if err != nil {
		return err
	}

	ctx := context.Background()
	reachable, err := ingest.Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		return fmt.Errorf("compute chunk closure for %q: %w", im.GetImageRef(), err)
	}

	client, err := registry.NewClient(url, registry.WithToken(resolveRegistryToken()))
	if err != nil {
		return fmt.Errorf("registry client: %w", err)
	}
	defer client.Close()

	// Convert the reachable set into a slice so the worker fan-out is
	// deterministic for the "already present" count is deterministic in
	// test assertions (map iteration order is random).
	ids := make([]chunkstore.ChunkID, 0, len(reachable))
	for id := range reachable {
		ids = append(ids, id)
	}

	// Live progress goes to stderr so it never pollutes the stdout summary
	// line that tests (and scripts) parse. The reporter starts in the
	// "negotiating" phase with a 0/0 total; pushChunks sets the real total
	// once the missing-chunk set is known.
	reporter := progress.New(errOut, 0, 0).Start("negotiating")

	uploaded, alreadyPresent, uploadBytes, err := pushChunks(ctx, client, store, ids, concurrency, reporter)
	reporter.Stop()
	if err != nil {
		return err
	}

	// Push the ImageManifest after the chunks so a `voila pull <ref>`
	// immediately after a successful push can resolve every chunk on demand.
	if err := client.PutImageManifest(ctx, im.GetImageRef(), im); err != nil {
		return fmt.Errorf("push manifest: %w", err)
	}

	// "X MiB" — report the bytes PUSHED (uploaded), not the closure size (the
	// closure may already exist on the registry). Use the same MiB-style
	// formatter as the rest of the CLI's human-readable output.
	fmt.Fprintf(out, "pushed %s: %d chunks uploaded, %d already present, %s\n",
		im.GetImageRef(), uploaded, alreadyPresent, cli.FormatBytes(uploadBytes))
	return nil
}

// pushChunks uploads every id in ids that the registry does not already
// hold. It first negotiates the missing set in ONE POST /v1/chunks/missing
// call (batched by the client at 16k ids/request), then PUTs only the missing
// chunks with `concurrency` workers (fail-fast). "already present" is the
// difference between the closure size and the missing set size.
//
// If the registry answers 404 on /v1/chunks/missing (it predates the
// bulk-stat endpoint), pushChunks falls back to pushChunksLegacy, which
// negotiates chunk-by-chunk via HEAD — one probe request decides the path.
//
// reporter is the live progress reporter (writes to stderr); it is given the
// real upload total here, once the missing set is known, and switched to the
// "uploading" phase. It may be nil (no progress reporting).
//
// Returns (uploaded, alreadyPresent, uploadedBytes, err). uploadedBytes is
// the sum of the LOGICAL (uncompressed) size of each newly uploaded chunk so
// the user-facing line reflects bytes actually moved over the wire.
func pushChunks(ctx context.Context, client *registry.Client, store chunkstore.ChunkStore, ids []chunkstore.ChunkID, concurrency int, reporter *progress.Reporter) (uploaded, alreadyPresent int, uploadedBytes uint64, err error) {
	if len(ids) == 0 {
		return 0, 0, 0, nil
	}
	missing, err := client.MissingChunks(ctx, ids)
	if err != nil {
		if errors.Is(err, registry.ErrBulkMissingUnsupported) {
			// Old registry — HEAD-per-chunk path. The probe was the one
			// /v1/chunks/missing request above; legacy takes it from here.
			return pushChunksLegacy(ctx, client, store, ids, concurrency, reporter)
		}
		return 0, 0, 0, err
	}
	alreadyPresent = len(ids) - len(missing)
	// Size the progress bar against the missing set: the bar fills as the
	// missing chunks upload. Sum the logical sizes via Stat (no fetch) so
	// the bar + ETA reflect bytes that will actually move over the wire.
	var totalBytes uint64
	for _, id := range missing {
		if meta, ok := store.Stat(id); ok {
			totalBytes += meta.LogicalLen
		}
	}
	if reporter != nil {
		reporter.SetTotal(len(missing), totalBytes)
		reporter.SetPhase("uploading")
	}
	uploaded, uploadedBytes, err = uploadChunks(ctx, client, store, missing, concurrency, reporter)
	return uploaded, alreadyPresent, uploadedBytes, err
}

// uploadChunks PUTs every chunk in ids (assumed already agreed missing by the
// bulk negotiation): a worker pool of `concurrency` goroutines reads from a
// shared input channel; the first error aborts the pool (fail-fast). It does
// NOT HEAD — the caller has already established what the registry lacks.
// reporter (if non-nil) receives Add(1, logicalBytes) per successful PUT.
// Returns (uploaded, uploadedBytes, err).
func uploadChunks(ctx context.Context, client *registry.Client, store chunkstore.ChunkStore, ids []chunkstore.ChunkID, concurrency int, reporter *progress.Reporter) (uploaded int, uploadedBytes uint64, err error) {
	if len(ids) == 0 {
		return 0, 0, nil
	}
	if concurrency < 1 {
		concurrency = 1
	}
	workCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	in := make(chan chunkstore.ChunkID)
	out := make(chan uploadResult)

	var wg sync.WaitGroup
	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			uploadWorker(workCtx, client, store, in, out, reporter)
		}()
	}
	// Producer: closes 'in' when ids are exhausted or ctx is cancelled.
	go func() {
		defer close(in)
		for _, id := range ids {
			select {
			case <-workCtx.Done():
				return
			case in <- id:
			}
		}
	}()
	// Closer: closes 'out' once all workers are done.
	go func() {
		wg.Wait()
		close(out)
	}()

	var (
		nUploaded int64
		nBytes    int64
	)
	var (
		firstErr error
		once     sync.Once
	)
	for r := range out {
		if r.err != nil {
			once.Do(func() {
				firstErr = r.err
				cancel() // unblocks producer + workers (fail-fast)
			})
			continue
		}
		atomic.AddInt64(&nUploaded, 1)
		atomic.AddInt64(&nBytes, int64(r.bytes))
	}
	if firstErr != nil {
		return int(atomic.LoadInt64(&nUploaded)), uint64(atomic.LoadInt64(&nBytes)), firstErr
	}
	return int(atomic.LoadInt64(&nUploaded)), uint64(atomic.LoadInt64(&nBytes)), nil
}

// uploadResult is the single-chunk outcome that flows out of an uploadWorker:
// either (bytes set) or (err set on failure).
type uploadResult struct {
	id    chunkstore.ChunkID
	bytes uint64
	err   error
}

// uploadWorker reads chunk ids from in, fetches each from the local store and
// PUTs it to the registry. The missing-set negotiation has already happened
// upstream, so it does NOT HEAD. ctx cancellation stops the worker by closing
// in from the producer side. reporter (if non-nil) is notified per successful
// PUT with the chunk's logical byte count.
//
// When the store implements chunkstore.StoredReader (LocalStore does), the
// worker uploads the STORED (zstd-compressed) bytes with a Content-Encoding
// header — a large bandwidth saving on compressible layers, since the raw
// bytes were stored compressed and would otherwise be re-expanded for the
// wire. The server decompresses before its BLAKE3 check, so the id (hash of
// the RAW content) still verifies. Stores that do not implement StoredReader
// fall back to Get + raw PutChunk.
func uploadWorker(ctx context.Context, client *registry.Client, store chunkstore.ChunkStore, in <-chan chunkstore.ChunkID, out chan<- uploadResult, reporter *progress.Reporter) {
	stored, canStored := store.(chunkstore.StoredReader)
	for id := range in {
		var logicalBytes uint64
		if canStored {
			data, algo, gerr := stored.GetStored(id)
			if gerr != nil {
				select {
				case out <- uploadResult{id: id, err: gerr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			if perr := client.PutChunkStored(ctx, id, data, algo); perr != nil {
				select {
				case out <- uploadResult{id: id, err: perr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			// Report the LOGICAL (raw) size so the bar + rate reflect the
			// user-visible payload, not the compressed wire bytes. Stat is
			// a cheap local lookup (no fetch).
			if meta, ok := store.Stat(id); ok {
				logicalBytes = meta.LogicalLen
			} else {
				logicalBytes = uint64(len(data))
			}
		} else {
			data, gerr := store.Get(ctx, id)
			if gerr != nil {
				select {
				case out <- uploadResult{id: id, err: gerr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			if perr := client.PutChunk(ctx, id, data); perr != nil {
				select {
				case out <- uploadResult{id: id, err: perr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			logicalBytes = uint64(len(data))
		}
		if reporter != nil {
			reporter.Add(1, logicalBytes)
		}
		select {
		case out <- uploadResult{id: id, bytes: logicalBytes}:
		case <-ctx.Done():
			return
		}
	}
}

// --- legacy per-chunk HEAD negotiation (fallback for old registries) ---

// pushChunksLegacy is the per-chunk-HEAD variant of pushChunks: it uses HEAD
// to negotiate missing chunks one at a time and PUTs the misses with a worker
// pool of `concurrency` goroutines (fail-fast). Used when the registry
// answers 404 on POST /v1/chunks/missing, i.e. predates the bulk-stat
// endpoint. The wire shape of the summary line is identical to the bulk path.
//
// The legacy path cannot size the progress bar up front (it does not know
// which chunks are missing until each HEAD returns), so the reporter keeps
// its 0/0 total and just counts up; the phase is switched to "uploading"
// here for parity with the bulk path.
func pushChunksLegacy(ctx context.Context, client *registry.Client, store chunkstore.ChunkStore, ids []chunkstore.ChunkID, concurrency int, reporter *progress.Reporter) (uploaded, alreadyPresent int, uploadedBytes uint64, err error) {
	if len(ids) == 0 {
		return 0, 0, 0, nil
	}
	if concurrency < 1 {
		concurrency = 1
	}
	if reporter != nil {
		reporter.SetPhase("uploading")
	}
	workCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	in := make(chan chunkstore.ChunkID)
	out := make(chan legacyResult)

	var wg sync.WaitGroup
	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			legacyHeadWorker(workCtx, client, store, in, out, reporter)
		}()
	}
	go func() {
		defer close(in)
		for _, id := range ids {
			select {
			case <-workCtx.Done():
				return
			case in <- id:
			}
		}
	}()
	go func() {
		wg.Wait()
		close(out)
	}()

	var (
		nUploaded int64
		nAlready  int64
		nBytes    int64
	)
	var (
		firstErr error
		once     sync.Once
	)
	for r := range out {
		if r.err != nil {
			once.Do(func() {
				firstErr = r.err
				cancel()
			})
			continue
		}
		if r.alreadyPresent {
			atomic.AddInt64(&nAlready, 1)
		} else {
			atomic.AddInt64(&nUploaded, 1)
			atomic.AddInt64(&nBytes, int64(r.bytes))
		}
	}
	if firstErr != nil {
		return int(atomic.LoadInt64(&nUploaded)), int(atomic.LoadInt64(&nAlready)),
			uint64(atomic.LoadInt64(&nBytes)), firstErr
	}
	return int(atomic.LoadInt64(&nUploaded)), int(atomic.LoadInt64(&nAlready)),
		uint64(atomic.LoadInt64(&nBytes)), nil
}

// legacyResult is the single-chunk outcome of legacyHeadWorker: either
// (alreadyPresent=true) or (bytes set, err set on failure).
type legacyResult struct {
	id             chunkstore.ChunkID
	alreadyPresent bool
	bytes          uint64
	err            error
}

// legacyHeadWorker reads chunk ids from in, HEADs each one; on a hit it emits
// alreadyPresent. On a miss it reads the chunk locally + PUTs it and reports
// the logical byte count. ctx cancellation stops the worker by closing in
// from the producer side. reporter (if non-nil) is notified per successful PUT.
func legacyHeadWorker(ctx context.Context, client *registry.Client, store chunkstore.ChunkStore, in <-chan chunkstore.ChunkID, out chan<- legacyResult, reporter *progress.Reporter) {
	stored, canStored := store.(chunkstore.StoredReader)
	for id := range in {
		// Cheap miss-detection: HEAD first.
		present, herr := client.HasChunk(ctx, id)
		if herr != nil {
			select {
			case out <- legacyResult{id: id, err: herr}:
			case <-ctx.Done():
				return
			}
			continue
		}
		if present {
			select {
			case out <- legacyResult{id: id, alreadyPresent: true}:
			case <-ctx.Done():
				return
			}
			continue
		}
		// Miss — fetch from local store and PUT. Prefer the stored
		// (compressed) form so the wire carries compressed bytes (see
		// uploadWorker for the full rationale).
		var logicalBytes uint64
		if canStored {
			data, algo, gerr := stored.GetStored(id)
			if gerr != nil {
				select {
				case out <- legacyResult{id: id, err: gerr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			if perr := client.PutChunkStored(ctx, id, data, algo); perr != nil {
				select {
				case out <- legacyResult{id: id, err: perr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			if meta, ok := store.Stat(id); ok {
				logicalBytes = meta.LogicalLen
			} else {
				logicalBytes = uint64(len(data))
			}
		} else {
			data, gerr := store.Get(ctx, id)
			if gerr != nil {
				select {
				case out <- legacyResult{id: id, err: gerr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			if perr := client.PutChunk(ctx, id, data); perr != nil {
				select {
				case out <- legacyResult{id: id, err: perr}:
				case <-ctx.Done():
					return
				}
				continue
			}
			logicalBytes = uint64(len(data))
		}
		if reporter != nil {
			reporter.Add(1, logicalBytes)
		}
		select {
		case out <- legacyResult{id: id, bytes: logicalBytes}:
		case <-ctx.Done():
			return
		}
	}
}
