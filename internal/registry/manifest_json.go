package registry

import (
	"encoding/hex"

	voilapb "voila/internal/proto"
)

// manifestJSON is the wire JSON representation of an ImageManifest. Chunk ids
// and digests are 64-char lowercase hex strings — the same encoding used in
// /v1/chunks/{id} paths and the /v1/chunks/missing endpoint — so a manifest
// fetched via `curl` can be inspected and its chunk ids pasted straight into a
// chunk URL. uint64 fields are plain JSON numbers (manifests are KB-scale; the
// values never approach 2^53 in practice).
//
// The canonical schema source remains internal/proto/image.proto; this struct
// is the wire-facing projection with hex-encoded bytes fields. The on-disk
// registry storage format is also JSON (see Server.writeImage).
type manifestJSON struct {
	ImageRef                string      `json:"image_ref"`
	ImageDigest             string      `json:"image_digest,omitempty"`
	ConfigChunk             string      `json:"config_chunk"`
	MergedRootManifestChunk string      `json:"merged_root_manifest_chunk"`
	ProvenanceLayers        []layerJSON `json:"provenance_layers,omitempty"`
	TotalSize               uint64      `json:"total_size"`
	ChunkCount              uint64      `json:"chunk_count"`
}

// layerJSON is the JSON projection of a single provenance Layer.
type layerJSON struct {
	RootManifestChunk string `json:"root_manifest_chunk"`
	WhiteoutsCount    uint64 `json:"whiteouts_count"`
}

// manifestToJSON converts a protobuf ImageManifest into its JSON wire form.
// Bytes fields (chunk ids, digest) are hex-encoded; empty bytes become "".
func manifestToJSON(im *voilapb.ImageManifest) *manifestJSON {
	m := &manifestJSON{
		ImageRef:                im.GetImageRef(),
		ImageDigest:             hex.EncodeToString(im.GetImageDigest()),
		ConfigChunk:             hex.EncodeToString(im.GetConfigChunk()),
		MergedRootManifestChunk: hex.EncodeToString(im.GetMergedRootManifestChunk()),
		TotalSize:               im.GetTotalSize(),
		ChunkCount:              im.GetChunkCount(),
	}
	for _, l := range im.GetProvenanceLayers() {
		m.ProvenanceLayers = append(m.ProvenanceLayers, layerJSON{
			RootManifestChunk: hex.EncodeToString(l.GetRootManifestChunk()),
			WhiteoutsCount:    l.GetWhiteoutsCount(),
		})
	}
	return m
}

// manifestFromJSON converts a JSON wire form back into a protobuf ImageManifest.
// Hex fields are decoded into bytes; empty strings decode to nil/empty bytes.
func manifestFromJSON(m *manifestJSON) (*voilapb.ImageManifest, error) {
	im := &voilapb.ImageManifest{
		ImageRef:   m.ImageRef,
		TotalSize:  m.TotalSize,
		ChunkCount: m.ChunkCount,
	}
	if m.ImageDigest != "" {
		b, err := hex.DecodeString(m.ImageDigest)
		if err != nil {
			return nil, err
		}
		im.ImageDigest = b
	}
	if m.ConfigChunk != "" {
		b, err := hex.DecodeString(m.ConfigChunk)
		if err != nil {
			return nil, err
		}
		im.ConfigChunk = b
	}
	if m.MergedRootManifestChunk != "" {
		b, err := hex.DecodeString(m.MergedRootManifestChunk)
		if err != nil {
			return nil, err
		}
		im.MergedRootManifestChunk = b
	}
	for _, l := range m.ProvenanceLayers {
		layer := &voilapb.Layer{WhiteoutsCount: l.WhiteoutsCount}
		if l.RootManifestChunk != "" {
			b, err := hex.DecodeString(l.RootManifestChunk)
			if err != nil {
				return nil, err
			}
			layer.RootManifestChunk = b
		}
		im.ProvenanceLayers = append(im.ProvenanceLayers, layer)
	}
	return im, nil
}
