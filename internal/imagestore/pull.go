package imagestore

import (
	"context"
	"fmt"

	"voila/internal/chunkstore"
	"voila/internal/ocireg"
	voilapb "voila/internal/proto"
)

// ManifestPuller is the minimal registry-client interface imagestore needs to
// fetch an ImageManifest by ref. It is defined HERE (in imagestore) so this
// package does not import internal/registry; cmd wires a real
// *registry.Client behind a small adapter. The single method's signature
// matches the existing registry.Client.GetImageManifest (a *voilapb.ImageManifest
// already unmarshaled by the HTTP client wrapper).
type ManifestPuller interface {
	GetImage(ctx context.Context, ref string) (*voilapb.ImageManifest, error)
}

// PullManifest fetches the ImageManifest pb for ref from the registry
// (via puller) and persists it locally: writes <root>/images/<refKey(ref)>.pb
// (reusing Store.WriteManifestPB) and upserts the images.db row with the
// totals the manifest carries (fields 6/7, populated at upload time). It does
// NOT download any chunk — that is the lazy-streaming point of Phase 1.
//
// The registry keys manifests under the ref they were pushed with (the
// canonical form ingestion stores). When fetching by the raw ref fails, the
// fetch is retried ONCE with ocireg.Canonical(ref) — so `voila pull
// python:3.13` finds a manifest pushed as
// `registry-1.docker.io/library/python:3.13` while refs pushed verbatim
// (e.g. private-registry names like "auto:v1") keep resolving on the first
// attempt.
//
// Returns the parsed ImageManifest so callers (cmd_pull, the resolve closure's
// auto-pull) can use it directly without re-reading the file.
func PullManifest(ctx context.Context, s *Store, puller ManifestPuller, ref string) (*voilapb.ImageManifest, error) {
	im, err := pullManifestOnce(ctx, s, puller, ref)
	if err != nil {
		if canon, ok := ocireg.Canonical(ref); ok && canon != ref {
			if im2, err2 := pullManifestOnce(ctx, s, puller, canon); err2 == nil {
				return im2, nil
			}
		}
		return nil, err
	}
	return im, nil
}

// pullManifestOnce performs a single registry fetch + persist pass for ref.
// It is the body of PullManifest; see that func for the retry semantics.
func pullManifestOnce(ctx context.Context, s *Store, puller ManifestPuller, ref string) (*voilapb.ImageManifest, error) {
	im, err := puller.GetImage(ctx, ref)
	if err != nil {
		// Passed through unwrapped: registry.Client errors are already
		// self-describing (*registry.ManifestError carries ref, registry,
		// cause); adding another layer here would duplicate both.
		return nil, err
	}
	// The manifest's ImageRef may differ only cosmetically (the registry
	// round-trips what push uploaded). If it is empty, fall back to ref so
	// the row + filename remain queryable.
	if im.GetImageRef() == "" {
		im.ImageRef = ref
	}
	storeRef := im.GetImageRef()
	if err := s.WriteManifestPB(storeRef, im); err != nil {
		return nil, fmt.Errorf("write image manifest: %w", err)
	}
	// Upsert the images.db row so Resolve / images / gc see the pulled
	// image. totals come from the manifest's fields 6/7 (filled at ingest
	// and preserved across push/pull). MergedRootManifest is the 32-byte
	// merged-root chunk id (the same value stored inside im).
	var mergedRoot []byte
	if len(im.GetMergedRootManifestChunk()) == len(chunkstore.ChunkID{}) {
		mergedRoot = im.GetMergedRootManifestChunk()
	}
	rec := Record{
		Ref:                storeRef,
		ImageDigest:        im.GetImageDigest(),
		MergedRootManifest: mergedRoot,
		TotalSize:          int64(im.GetTotalSize()),
		ChunkCount:         int64(im.GetChunkCount()),
	}
	if err := s.Upsert(rec); err != nil {
		return nil, err
	}
	return im, nil
}

// AutoPull attempts to fetch the ImageManifest for query from the registry
// (via puller) and persist it locally. Returns (im, true) on success; (nil,
// false) when the call fails OR query is not a plausible ref (e.g. a digest
// prefix — the v0.2 protocol stores manifests keyed by ref only, so a digest
// prefix has no path to a manifest and we fail without burning a network
// round-trip that would 404 anyway). On any error we silently fall back to
// failing the calling Resolve closure's normal "no image matching" error,
// so the user sees the same shape of failure either way.
//
// A nil puller (no registry configured) returns (nil, false) without touching
// the network; query=="" likewise. Note: callers must pass a truly-nil
// ManifestPuller (not an interface wrapping a nil pointer) to trigger the
// non-registry short-circuit — the cmd helpers construct a nil interface
// variable and only assign a concrete puller when a registry client is non-nil.
func AutoPull(query string, s *Store, puller ManifestPuller) (*voilapb.ImageManifest, bool) {
	if puller == nil || query == "" {
		return nil, false
	}
	// Heuristic: a digest prefix has no '/' or ':' and is short-hex; the
	// registry stores by ref, so skip the network call.
	if !LooksLikeRef(query) {
		return nil, false
	}
	ctx := context.Background()
	im, err := PullManifest(ctx, s, puller, query)
	if err != nil {
		return nil, false
	}
	return im, true
}

// LooksLikeRef is a loose heuristic: real image refs almost always contain
// either a ':' (tag separator) or a '/' (registry/repo path). A bare
// 64-hex digest prefix has neither, and the registry protocol keys
// manifests under the ref — so we treat queries without ':' or '/' as
// not-refs and skip the auto-pull network call.
func LooksLikeRef(query string) bool {
	for i := 0; i < len(query); i++ {
		c := query[i]
		if c == ':' || c == '/' {
			return true
		}
	}
	return false
}

// RootChunkFromManifest returns the merged-root manifest chunk id from im,
// or an error if the field is malformed. Mirrors the check Resolve performs
// after LoadImageManifest; factored here so the auto-pull path can re-derive
// rootChunk from a freshly-pulled manifest without re-reading the .pb file.
func RootChunkFromManifest(im *voilapb.ImageManifest) (chunkstore.ChunkID, error) {
	if len(im.GetMergedRootManifestChunk()) != len(chunkstore.ChunkID{}) {
		return chunkstore.ChunkID{}, fmt.Errorf("image %q: merged root manifest chunk is not 32 bytes", im.GetImageRef())
	}
	var id chunkstore.ChunkID
	copy(id[:], im.GetMergedRootManifestChunk())
	return id, nil
}
