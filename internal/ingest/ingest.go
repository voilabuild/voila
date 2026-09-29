package ingest

import (
	"archive/tar"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"

	"voila/internal/chunkstore"
)

// Options configure an Ingest run.
type Options struct {
	// Platform selects among multi-platform OCI image indexes, e.g.
	// "linux/arm64". Defaults to runtime.GOOS/GOARCH.
	Platform string
	// Ref optionally overrides the image ref; default is the ref found in the
	// tarball metadata (legacy RepoTags; OCI images carry no ref, so the ref
	// stays empty unless set here).
	Ref string
	// LayerCache, when non-nil, turns Ingest into a memoized load: any layer
	// whose OCI blob digest is already cached has its manifest chunk
	// DecodeTree'd into the layer slot instead of being re-walked, and is
	// counted in Result.LayersReused. The legacy docker-save layout carries
	// no per-layer digest, so its layers are never cached (Lookup and Store
	// are both skipped for them). nil disables caching entirely (the default
	// for programmatic callers and the e2e tests).
	LayerCache LayerCache
}

// LayerResult is one provenance layer's outcome.
type LayerResult struct {
	RootManifestChunk chunkstore.ChunkID
	WhiteoutsCount    uint64
}

// Result is the full outcome of an Ingest run. The caller (CLI, later task)
// writes the ImageManifest JSON/proto file and sqlite row.
type Result struct {
	Ref                     string
	ImageDigest             []byte
	ConfigChunk             chunkstore.ChunkID
	MergedRootManifestChunk chunkstore.ChunkID
	Layers                  []LayerResult
	BytesIn                 uint64
	ChunkCount              uint64
	ChunksDeduped           uint64
	StoredBytes             uint64
	// LayersReused counts per-layer provenance manifests served from the
	// LayerCache instead of a fresh tar walk. Total layers is len(Layers).
	// Surfaced in the CLI ingest summary as "layers reused: N/M".
	LayersReused uint64
}

// Ingest reads an OCI-layout or legacy docker-save tarball at tarballPath,
// streams its layers through store (chunking regular-file content), merges
// the per-layer trees, and encodes the merged + per-layer manifests as
// chunk-addressed protobuf. It never extracts to a temp dir; blob content is
// streamed directly off the outer tar.
func Ingest(ctx context.Context, tarballPath string, store chunkstore.ChunkStore, opts Options) (*Result, error) {
	if store == nil {
		return nil, errors.New("ingest: nil chunk store")
	}

	pl, err := parseLayout(tarballPath, &opts)
	if err != nil {
		return nil, err
	}

	layerTrees, layerManifestChunk, reused, layersReused := cachePrePass(ctx, store, &opts, pl)

	var configChunk chunkstore.ChunkID
	var haveConfig bool
	var aggBytesIn, aggChunkCount, aggDeduped, aggStored uint64

	layerPath := make(map[string]*layerDesc, len(pl.layers))
	for i := range pl.layers {
		if reused[i] {
			// Already served from cache; do not re-stream its blob.
			continue
		}
		layerPath[pl.layers[i].path] = &pl.layers[i]
	}

	if err := streamOuter(ctx, tarballPath, func(name string, r io.Reader, size int64) error {
		switch {
		case name == pl.configPath:
			data, err := io.ReadAll(io.LimitReader(r, configBufferMax))
			if err != nil {
				return err
			}
			id, err := store.Put(data)
			if err != nil {
				return err
			}
			configChunk = id
			haveConfig = true
			return nil
		case layerPath[name] != nil:
			desc := layerPath[name]
			dr, _, err := DecompressLayer(io.LimitReader(r, size), desc.hint)
			if err != nil {
				return fmt.Errorf("layer %q decompress: %w", name, err)
			}
			res, err := WalkLayer(ctx, dr, store)
			if err != nil {
				return fmt.Errorf("layer %q walk: %w", name, err)
			}
			layerTrees[desc.index] = res.Tree
			aggBytesIn += res.BytesIn
			aggChunkCount += res.ChunkCount
			aggDeduped += res.ChunksDeduped
			aggStored += res.StoredBytes
			return nil
		default:
			return nil
		}
	}); err != nil {
		return nil, err
	}

	if !haveConfig {
		return nil, fmt.Errorf("ingest: config blob %q not found in tarball", pl.configPath)
	}
	for i, lt := range layerTrees {
		if lt == nil {
			return nil, fmt.Errorf("ingest: layer blob %q not found in tarball", pl.layers[i].path)
		}
	}

	return buildIngestResult(ctx, store, &opts, pl, layerTrees, layerManifestChunk, reused, layersReused,
		configChunk, aggBytesIn, aggChunkCount, aggDeduped, aggStored)
}

// cachePrePass performs the per-layer manifest cache lookup BEFORE any blob is
// streamed. For each layer with a trustworthy pre-stream digest (OCI layouts
// only — the legacy docker-save layout carries no digest) it looks the layer
// up in opts.LayerCache and, on a hit, DecodeTree's the cached manifest chunk
// into the layer slot and Stat's its content chunks via VerifyTreeChunks. If
// any chunk is missing (gc reclaimed it) the hit is discarded and the layer is
// left to be walked fresh. Returns the per-layer tree slots (populated only
// for cache hits), the cached manifest chunk ids, the reused mask, and the
// count of layers served from the cache. Shared by the tarball and registry
// ingest paths.
func cachePrePass(ctx context.Context, store chunkstore.ChunkStore, opts *Options, pl *parsedLayout) (
	layerTrees []*LayerTree, layerManifestChunk []chunkstore.ChunkID, reused []bool, layersReused uint64,
) {
	layerTrees = make([]*LayerTree, len(pl.layers))
	layerManifestChunk = make([]chunkstore.ChunkID, len(pl.layers))
	reused = make([]bool, len(pl.layers))

	if opts.LayerCache == nil {
		return layerTrees, layerManifestChunk, reused, 0
	}
	for i, ld := range pl.layers {
		if ld.digest == "" {
			continue
		}
		manifestChunk, ok := opts.LayerCache.Lookup(ld.digest)
		if !ok {
			continue
		}
		tree, derr := DecodeTree(ctx, store, manifestChunk)
		if derr != nil {
			// Manifest chunk (or an external_subtrees chunk) was collected by
			// gc: fall back to a fresh walk.
			continue
		}
		if !VerifyTreeChunks(ctx, tree, store) {
			// A content chunk referenced by the decoded tree was collected by
			// gc: fall back to a fresh walk so the file content is re-chunked.
			continue
		}
		layerTrees[i] = tree
		layerManifestChunk[i] = manifestChunk
		reused[i] = true
		layersReused++
	}
	return layerTrees, layerManifestChunk, reused, layersReused
}

// buildIngestResult merges the per-layer trees lower→upper, builds + stores
// the per-layer provenance manifests and the merged root manifest, and
// assembles the Result. It is the shared tail of the tarball and registry
// ingest paths: both have walked (or cache-served) layer trees + a config
// chunk + the aggregate byte/chunk counters, and both need the same merge +
// manifest-build + cache-store + ref/digest resolution.
//
// For layers served from the cache (reused[i]) the manifest chunk id is reused
// as-is: the cached manifest bytes are byte-identical to a fresh build
// (BuildLayerManifest is deterministic), so re-storing would only burn an
// idempotent Put. For freshly walked layers the manifest is built + stored and
// the (digest, chunk) pair is handed back to the cache so the next ingest of a
// layer with the same blob digest hits. Whiteout-bearing layers are NEVER
// cached: the Manifest proto does not serialize whiteout/opaque markers, so a
// cache hit would rebuild the layer tree without them and the merge would
// silently resurrect files the layer deletes.
func buildIngestResult(
	ctx context.Context, store chunkstore.ChunkStore, opts *Options, pl *parsedLayout,
	layerTrees []*LayerTree, layerManifestChunk []chunkstore.ChunkID, reused []bool, layersReused uint64,
	configChunk chunkstore.ChunkID,
	aggBytesIn, aggChunkCount, aggDeduped, aggStored uint64,
) (*Result, error) {
	// Merge per-layer trees lower→upper. MergeTrees copies nodes; the layer
	// trees remain free to mutate afterwards.
	merged, err := MergeTrees(layerTrees)
	if err != nil {
		return nil, err
	}

	layers := make([]LayerResult, len(layerTrees))
	for i, lt := range layerTrees {
		chunk := layerManifestChunk[i]
		if !reused[i] {
			c, err := BuildAndStoreLayerManifest(lt, store)
			if err != nil {
				return nil, fmt.Errorf("layer %d manifest: %w", i, err)
			}
			chunk = c
			if opts.LayerCache != nil && pl.layers[i].digest != "" &&
				lt.WhiteoutsN == 0 && lt.OpaqueN == 0 {
				if err := opts.LayerCache.Store(pl.layers[i].digest, chunk); err != nil {
					return nil, fmt.Errorf("layer %d cache store: %w", i, err)
				}
			}
		}
		layers[i] = LayerResult{
			RootManifestChunk: chunk,
			WhiteoutsCount:    lt.WhiteoutsN + lt.OpaqueN,
		}
	}

	// Build + store the merged root manifest.
	rootChunk, err := BuildAndStoreManifest(merged, store)
	if err != nil {
		return nil, fmt.Errorf("merged root manifest: %w", err)
	}

	ref := pl.ref
	if opts.Ref != "" {
		ref = opts.Ref
	}
	imageDigest := pl.imageDigest
	if imageDigest == nil {
		// Legacy fallback: compute SHA-256 of the config JSON. We re-read
		// config bytes through the store so we don't re-scan; if the chunk
		// is unavailable the digest stays nil. For legacy docker-save we
		// approximate the image digest with the config's SHA-256.
		if cfg, err := store.Get(ctx, configChunk); err == nil {
			sum := sha256.Sum256(cfg)
			imageDigest = sum[:]
		}
	}

	return &Result{
		Ref:                     ref,
		ImageDigest:             imageDigest,
		ConfigChunk:             configChunk,
		MergedRootManifestChunk: rootChunk,
		Layers:                  layers,
		BytesIn:                 aggBytesIn,
		ChunkCount:              aggChunkCount,
		ChunksDeduped:           aggDeduped,
		StoredBytes:             aggStored,
		LayersReused:            layersReused,
	}, nil
}

// streamOuter opens the outer tarball and invokes fn for each entry with a
// reader bounded to that entry's size. fn must read at most size bytes.
func streamOuter(ctx context.Context, tarballPath string, fn func(name string, r io.Reader, size int64) error) error {
	f, err := os.Open(tarballPath)
	if err != nil {
		return err
	}
	defer f.Close()
	tr := tar.NewReader(f)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("ingest: stream outer tar: %w", err)
		}
		name := cleanOuterPath(hdr.Name)
		if err := fn(name, tr, hdr.Size); err != nil {
			return err
		}
	}
}

// configBufferMax bounds how much of a config JSON we buffer to Put as a chunk.
// OCI image configs are tiny (low hundreds of KiB at most).
const configBufferMax = 16 << 20 // 16 MiB
