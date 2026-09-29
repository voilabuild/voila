// Package ingest's layer_cache.go is the seam for the per-layer manifest
// cache (plan §12 "Layer identity" + task 13 Part C). A LayerCache maps an OCI
// layer blob digest ("sha256:<hex>", the manifest's layer descriptor digest —
// a trustworthy pre-stream key for OCI-layout tarballs) to the chunk id of
// that layer's stored per-layer manifest. On a cache hit, Ingest skips the tar
// walk entirely and DecodeTree's the cached manifest chunk into the layer
// tree slot, counting LayersReused in the Result. On a miss, the layer is
// walked as today, the per-layer manifest is built + stored, and the chunk id
// is handed back to the cache via Store.
//
// The legacy docker-save layout carries no per-layer digest in its
// manifest.json, so it has no trustworthy pre-stream key; both Lookup and
// Store are skipped for legacy layers (the digest is "" — see oci_layout.go).
//
// Correctness guard (plan §13.2): a cache hit is only usable when the manifest
// chunk AND every content block chunk referenced by the decoded tree are
// still present locally — gc may have removed them. DecodeTree already
// fetches every manifest chunk (transitively through external_subtrees), so a
// missing manifest chunk surfaces as a decode error and Ingest falls back to
// a fresh walk. Content chunks are not fetched by DecodeTree, so VerifyTreeChunks
// Stat's every block chunk id (cheap sqlite point lookups) and reports
// false when any is missing, again triggering the fresh-walk fallback.
package ingest

import (
	"context"

	"voila/internal/chunkstore"
)

// LayerCache maps an OCI layer blob digest (canonical "sha256:<hex>") to the
// chunk id of that layer's stored per-layer manifest. Implementations must be
// safe for concurrent use by multiple Ingest runs sharing one store.
//
// Lookup returns ok=false when no entry exists for the digest. Store is
// idempotent: storing the same (digest, chunk) twice is a no-op.
//
// nil means "no caching": Ingest skips both the lookup pre-pass and the
// post-walk Store, walking every layer as today. This is the default for
// programmatic callers (tests, the e2e harness) and is also the behaviour for
// legacy docker-save layers, which carry no trustworthy per-layer digest.
type LayerCache interface {
	Lookup(ociDigest string) (manifestChunk chunkstore.ChunkID, ok bool)
	Store(ociDigest string, manifestChunk chunkstore.ChunkID) error
}

// VerifyTreeChunks reports whether every content (block) chunk referenced by
// tree's regular-file nodes is present in store (via Stat — a cheap sqlite
// point lookup, no content fetch). It returns false on the first missing
// chunk. Used by Ingest's cache-hit path to fall back to a fresh walk when gc
// has reclaimed some of a cached layer's content chunks; the cached manifest
// chunk itself is checked by DecodeTree (a missing manifest chunk makes
// DecodeTree fail).
//
// Inodes that carry no blocks (symlinks, devices, dirs, pending hardlinks, and
// zero-length regular files) reference no chunks and are skipped. Holes in a
// regular file are encoded as Block entries with an empty ChunkId
// (logical_len > 0, chunk_id = "") — those are skipped too (they reference
// no stored chunk).
func VerifyTreeChunks(ctx context.Context, tree *LayerTree, store chunkstore.ChunkStore) bool {
	if store == nil || tree == nil {
		return false
	}
	_ = ctx
	for _, n := range tree.byPath {
		if n == nil || n.Type != NodeRegular {
			continue
		}
		for _, b := range n.Blocks {
			id, ok := chunkIDFromBytes(b.GetChunkId())
			if !ok {
				// Hole / sparse block: no chunk referenced.
				continue
			}
			if _, present := store.Stat(id); !present {
				return false
			}
		}
	}
	return true
}
