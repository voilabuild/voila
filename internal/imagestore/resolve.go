package imagestore

import (
	"encoding/hex"
	"fmt"
	"strings"

	"voila/internal/chunkstore"
	"voila/internal/ocireg"
	voilapb "voila/internal/proto"
)

// Resolve resolves query to the stored ImageManifest and merged-root manifest
// chunk. The resolution rules (plan §6 / task spec):
//   - exact match on image ref in images.db → use that row
//   - else normalize the query with the SAME rules ingestion applies
//     (ocireg.Canonical: docker.io alias, library/ namespace, implicit
//     ":latest") and retry the exact match — so `voila run python:3.13`
//     finds the row stored as `registry-1.docker.io/library/python:3.13`
//   - else treat query as a digest prefix; if it matches exactly one
//     image_digest, use it; zero matches → "no image matching %q", >1 →
//     ambiguous error (matches: <refs>)
//
// On success, returns the unmarshaled ImageManifest and its merged-root
// manifest chunk id.
func Resolve(s *Store, query string) (*voilapb.ImageManifest, chunkstore.ChunkID, error) {
	rows, err := s.List()
	if err != nil {
		return nil, chunkstore.ChunkID{}, fmt.Errorf("list images: %w", err)
	}
	// 1. Exact ref match.
	for _, r := range rows {
		if r.Ref == query {
			return s.LoadImageManifest(r.Ref)
		}
	}
	// 2. Normalized ref match: canonicalize with ingestion's rules and
	// retry. Skipped when the query does not parse (e.g. a digest prefix)
	// or canonicalizes to the query itself (already covered by step 1).
	if canon, ok := ocireg.Canonical(query); ok && canon != query {
		for _, r := range rows {
			if r.Ref == canon {
				return s.LoadImageManifest(r.Ref)
			}
		}
	}
	// 3. Digest prefix match.
	queryHex := strings.ToLower(stripDigestScheme(query))
	if queryHex == "" {
		return nil, chunkstore.ChunkID{}, fmt.Errorf("no image matching %q", query)
	}
	var hits []Record
	for _, r := range rows {
		digHex := hex.EncodeToString(r.ImageDigest)
		if len(queryHex) > len(digHex) {
			continue
		}
		if digHex[:len(queryHex)] == queryHex {
			hits = append(hits, r)
		}
	}
	switch len(hits) {
	case 0:
		return nil, chunkstore.ChunkID{}, fmt.Errorf("no image matching %q", query)
	case 1:
		return s.LoadImageManifest(hits[0].Ref)
	default:
		refs := make([]string, 0, len(hits))
		for _, h := range hits {
			refs = append(refs, h.Ref)
		}
		return nil, chunkstore.ChunkID{}, fmt.Errorf("ambiguous digest prefix %q (matches: %v)", query, refs)
	}
}

// stripDigestScheme trims a leading "sha256:" / "sha512:"-style scheme.
func stripDigestScheme(s string) string {
	for _, p := range []string{"sha256:", "sha512:", "sha:", "blake3:"} {
		if len(s) > len(p) && s[:len(p)] == p {
			return s[len(p):]
		}
	}
	return s
}
