package build

import (
	"fmt"
	"sort"

	"lukechampine.com/blake3"

	"voila/internal/chunkstore"
	"voila/internal/dockerfile"
)

// CacheKey computes the instruction cache key for an instruction given the
// parent merged-root manifest chunk and optional extra material (COPY sources).
func CacheKey(parentRoot chunkstore.ChunkID, inst dockerfile.Instruction, extra string) string {
	h := blake3.New(32, nil)
	h.Write(parentRoot[:])
	h.Write([]byte(dockerfile.Canonical(inst)))
	if extra != "" {
		h.Write([]byte{0})
		h.Write([]byte(extra))
	}
	sum := h.Sum(nil)
	return fmt.Sprintf("%x", sum)
}

// CopyExtra builds the extra cache material for COPY/ADD: sorted context paths
// and per-file content hashes.
func CopyExtra(paths []string, hashes map[string]string) string {
	if len(paths) == 0 {
		return ""
	}
	sorted := append([]string(nil), paths...)
	sort.Strings(sorted)
	var b []byte
	for _, p := range sorted {
		b = append(b, []byte(p)...)
		b = append(b, 0)
		if hashes != nil {
			b = append(b, []byte(hashes[p])...)
			b = append(b, 0)
		}
	}
	return string(b)
}
