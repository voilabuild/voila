// ingest_registry.go is the registry-source counterpart to Ingest (which
// reads a tarball). It pulls an image straight from an OCI Distribution v2
// registry (via an ocireg.Client), feeds the config + layer blobs into the
// SAME chunking / merge / manifest-build pipeline, and returns a Result
// indistinguishable from a tarball ingest. This is what backs `voila import
// <ref>` — no Docker daemon, no `docker save` tarball on disk.
//
// The blob source is the only difference from the tarball path: instead of a
// single streamOuter pass over an outer tar, we fetch the config blob and each
// layer blob by digest over HTTP and hand them to DecompressLayer + WalkLayer.
// The cache pre-pass, merge, per-layer + root manifest build, and ref/digest
// resolution are shared (cachePrePass + buildIngestResult).
package ingest

import (
	"context"
	"errors"
	"fmt"
	"io"

	"voila/internal/chunkstore"
	"voila/internal/ocireg"
)

// RegistryClient is the minimal slice of *ocireg.Client that IngestRegistry
// uses. Declared as an interface so tests can substitute a fake without
// spinning up an HTTP server. Production callers pass a *ocireg.Client.
type RegistryClient interface {
	// Resolve fetches ref's manifest, descending a manifest list to the
	// concrete image manifest for platform ("" = runtime default).
	Resolve(ctx context.Context, ref ocireg.Ref, platform string) (*ocireg.Manifest, error)
	// Blob streams the blob identified by digest under ref's repository.
	Blob(ctx context.Context, ref ocireg.Ref, digest string) (io.ReadCloser, int64, error)
}

// IngestRegistry pulls ref from an OCI Distribution v2 registry via client and
// ingests it into store. It is the registry-source twin of Ingest: the config
// blob → a chunk, each layer blob → DecompressLayer + WalkLayer, then the
// shared merge + manifest-build tail. opts.Ref overrides the stored ref
// (default: ref.String()); opts.Platform selects among a manifest list.
func IngestRegistry(ctx context.Context, client RegistryClient, ref ocireg.Ref, store chunkstore.ChunkStore, opts Options) (*Result, error) {
	if store == nil {
		return nil, errors.New("ingest: nil chunk store")
	}
	if client == nil {
		return nil, errors.New("ingest: nil registry client")
	}

	man, err := client.Resolve(ctx, ref, opts.Platform)
	if err != nil {
		return nil, fmt.Errorf("ingest: resolve %s: %w", ref.String(), err)
	}

	pl, err := layoutFromRegistry(man, ref, opts)
	if err != nil {
		return nil, err
	}

	layerTrees, layerManifestChunk, reused, layersReused := cachePrePass(ctx, store, &opts, pl)

	var configChunk chunkstore.ChunkID
	var haveConfig bool
	var aggBytesIn, aggChunkCount, aggDeduped, aggStored uint64

	// Config blob → chunk.
	cfgR, _, err := client.Blob(ctx, ref, pl.configPath)
	if err != nil {
		return nil, fmt.Errorf("ingest: fetch config blob: %w", err)
	}
	cfgBytes, err := io.ReadAll(io.LimitReader(cfgR, configBufferMax))
	_ = cfgR.Close()
	if err != nil {
		return nil, fmt.Errorf("ingest: read config blob: %w", err)
	}
	id, err := store.Put(cfgBytes)
	if err != nil {
		return nil, fmt.Errorf("ingest: store config blob: %w", err)
	}
	configChunk = id
	haveConfig = true

	// Each non-cached layer blob → DecompressLayer → WalkLayer. Layers are
	// fetched in lower→upper order; a cached layer (reused[i]) is skipped
	// entirely — no HTTP request is made for it.
	for i := range pl.layers {
		if reused[i] {
			continue
		}
		ld := pl.layers[i]
		blobR, _, err := client.Blob(ctx, ref, ld.digest)
		if err != nil {
			return nil, fmt.Errorf("ingest: fetch layer %d blob: %w", i, err)
		}
		dr, _, err := DecompressLayer(blobR, ld.hint)
		if err != nil {
			_ = blobR.Close()
			return nil, fmt.Errorf("ingest: layer %d decompress: %w", i, err)
		}
		res, err := WalkLayer(ctx, dr, store)
		_ = blobR.Close()
		if err != nil {
			return nil, fmt.Errorf("ingest: layer %d walk: %w", i, err)
		}
		layerTrees[i] = res.Tree
		aggBytesIn += res.BytesIn
		aggChunkCount += res.ChunkCount
		aggDeduped += res.ChunksDeduped
		aggStored += res.StoredBytes
	}

	if !haveConfig {
		return nil, fmt.Errorf("ingest: config blob %q not found", pl.configPath)
	}
	for i, lt := range layerTrees {
		if lt == nil {
			return nil, fmt.Errorf("ingest: layer blob %q not found", pl.layers[i].digest)
		}
	}

	return buildIngestResult(ctx, store, &opts, pl, layerTrees, layerManifestChunk, reused, layersReused,
		configChunk, aggBytesIn, aggChunkCount, aggDeduped, aggStored)
}

// layoutFromRegistry builds the parsedLayout that drives the shared ingest
// tail from a resolved registry manifest. The config "path" is the config
// blob's digest (the registry fetch key); each layer's "path" is unused (the
// registry dispatch fetches by digest), but its digest + compression hint are
// set so the cache pre-pass and the cache Store after the walk both work —
// identical to an OCI-layout tarball ingest.
func layoutFromRegistry(man *ocireg.Manifest, ref ocireg.Ref, opts Options) (*parsedLayout, error) {
	if man.Config.Digest == "" {
		return nil, fmt.Errorf("ingest: manifest %s has no config digest", ref.String())
	}
	layers := make([]layerDesc, len(man.Layers))
	for i, l := range man.Layers {
		if l.Digest == "" {
			return nil, fmt.Errorf("ingest: layer %d has no digest", i)
		}
		layers[i] = layerDesc{
			path:   l.Digest, // unused for registry dispatch; kept for parity.
			index:  i,
			hint:   mediaTypeHint(l.MediaType),
			digest: l.Digest,
		}
	}

	imageDigest, _ := digestToBytes(man.Digest)

	return &parsedLayout{
		kind:        layoutOCI,
		ref:         ref.String(),
		imageDigest: imageDigest,
		configPath:  man.Config.Digest,
		layers:      layers,
	}, nil
}
