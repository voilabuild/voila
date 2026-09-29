// Package ingest's reachable.go implements the chunk-reachability walk used by
// `voila images gc` (plan §11.5). Given the set of remaining ImageManifests,
// Reachable returns the transitive set of ChunkIDs that must be retained:
// every image's config chunk, the merged-root manifest chunk and each
// per-layer provenance manifest chunk, every File.block chunk_id, and every
// Manifest chunk reachable via external_subtrees (transitively — split
// subtrees may themselves split further).
//
// A missing chunk mid-walk is treated as a corrupt store: Reachable returns an
// error rather than a partial set, so `voila images gc` refuses to delete
// anything (the spec says do NOT gc on errors).
package ingest

import (
	"context"
	"fmt"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// Reachable returns the transitive set of chunks the given images still
// reference. The returned map is suitable to hand directly to
// ChunkStore.GC as the "keep" set. Every chunk reachable from any image in
// images is included; any chunk NOT in the set is garbage.
//
// Reachable fails closed: a store.Get error or an unmarshal error aborts the
// walk and returns the error with no reachable set, so the caller can refuse
// to GC a corrupt store rather than risk deleting live chunks.
// ClosureStats returns the chunk count and total logical byte size of an
// image's transitive chunk closure (the same walk Reachable uses).
func ClosureStats(ctx context.Context, store chunkstore.ChunkStore, im *voilapb.ImageManifest) (chunkCount, logicalBytes uint64, err error) {
	reachable, err := Reachable(ctx, store, []*voilapb.ImageManifest{im})
	if err != nil {
		return 0, 0, err
	}
	for id := range reachable {
		chunkCount++
		if meta, ok := store.Stat(id); ok {
			logicalBytes += meta.LogicalLen
		}
	}
	return chunkCount, logicalBytes, nil
}

func Reachable(ctx context.Context, store chunkstore.ChunkStore, images []*voilapb.ImageManifest) (map[chunkstore.ChunkID]struct{}, error) {
	if store == nil {
		return nil, fmt.Errorf("ingest: nil chunk store")
	}
	reachable := make(map[chunkstore.ChunkID]struct{})
	for _, im := range images {
		if im == nil {
			continue
		}
		if err := addImageReachable(ctx, store, im, reachable); err != nil {
			return nil, err
		}
	}
	return reachable, nil
}

// addImageReachable seeds and walks the reachability set for a single image:
// the config chunk, the merged-root manifest chunk, and each provenance
// layer's root manifest chunk. Each manifest chunk is walked via
// walkManifestTransitive.
func addImageReachable(ctx context.Context, store chunkstore.ChunkStore, im *voilapb.ImageManifest, reachable map[chunkstore.ChunkID]struct{}) error {
	// Config chunk.
	if len(im.GetConfigChunk()) != len(chunkstore.ChunkID{}) {
		return fmt.Errorf("image %q: config chunk is not 32 bytes", im.GetImageRef())
	}
	if id, ok := chunkIDFromBytes(im.GetConfigChunk()); ok {
		reachable[id] = struct{}{}
		// The config chunk is opaque content (the OCI image config JSON); it
		// has no child chunks, so no further walk is needed.
	}

	// Merged root manifest chunk.
	if len(im.GetMergedRootManifestChunk()) != len(chunkstore.ChunkID{}) {
		return fmt.Errorf("image %q: merged root manifest chunk is not 32 bytes", im.GetImageRef())
	}
	if id, ok := chunkIDFromBytes(im.GetMergedRootManifestChunk()); ok {
		if err := walkManifestTransitive(ctx, store, id, reachable); err != nil {
			return fmt.Errorf("image %q: merged root manifest: %w", im.GetImageRef(), err)
		}
	}

	// Per-layer provenance manifest chunks.
	for i, l := range im.GetProvenanceLayers() {
		if l == nil {
			continue
		}
		if len(l.GetRootManifestChunk()) != len(chunkstore.ChunkID{}) {
			return fmt.Errorf("image %q: layer %d root manifest chunk is not 32 bytes", im.GetImageRef(), i)
		}
		id, ok := chunkIDFromBytes(l.GetRootManifestChunk())
		if !ok {
			continue
		}
		if err := walkManifestTransitive(ctx, store, id, reachable); err != nil {
			return fmt.Errorf("image %q: layer %d manifest: %w", im.GetImageRef(), i, err)
		}
	}
	return nil
}

// walkManifestTransitive performs a depth-first walk of the manifest tree
// rooted at rootID. rootID and every chunk referenced anywhere in the tree
// (File block chunk_ids, every external_subtrees chunk transitive closure)
// are added to reachable. A chunk already in reachable short-circuits the
// recursion so two images sharing a subtree do not double-walk it.
//
// A missing manifest chunk produces an error (corrupt store); the spec says
// gc must refuse on errors.
func walkManifestTransitive(ctx context.Context, store chunkstore.ChunkStore, rootID chunkstore.ChunkID, reachable map[chunkstore.ChunkID]struct{}) error {
	if _, seen := reachable[rootID]; seen {
		return nil
	}
	reachable[rootID] = struct{}{}

	data, err := store.Get(ctx, rootID)
	if err != nil {
		return fmt.Errorf("get manifest chunk %s: %w", rootID, err)
	}
	m := &voilapb.Manifest{}
	if err := proto.Unmarshal(data, m); err != nil {
		return fmt.Errorf("unmarshal manifest chunk %s: %w", rootID, err)
	}

	// File block chunks (content). Each File's Blocks is an ordered list;
	// sparse holes carry an empty chunk_id (len 0) and reference no chunk.
	for _, f := range m.GetFiles() {
		for _, b := range f.GetBlocks() {
			if id, ok := chunkIDFromBytes(b.GetChunkId()); ok {
				if _, seen := reachable[id]; !seen {
					// File content chunks are leaves; they reference no
					// further chunks but we still want them in the keep set.
					reachable[id] = struct{}{}
				}
			}
		}
	}

	// External subtree chunks: each is itself a Manifest chunk so recurse.
	for _, raw := range m.GetExternalSubtrees() {
		id, ok := chunkIDFromBytes(raw)
		if !ok {
			return fmt.Errorf("manifest chunk %s: external_subtrees entry is not 32 bytes", rootID)
		}
		if err := walkManifestTransitive(ctx, store, id, reachable); err != nil {
			return err
		}
	}
	return nil
}

// chunkIDFromBytes returns the ChunkID encoded by b and ok=true iff b carries
// exactly 32 bytes (ChunkID's underlying array length).
func chunkIDFromBytes(b []byte) (chunkstore.ChunkID, bool) {
	if len(b) != len(chunkstore.ChunkID{}) {
		return chunkstore.ChunkID{}, false
	}
	var id chunkstore.ChunkID
	copy(id[:], b)
	return id, true
}
