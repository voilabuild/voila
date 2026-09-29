package chunkstore

import "path/filepath"

// blobPath returns the sharded on-disk path for a chunk under root.
// Layout: <root>/chunks/ab/cd/<full-64-char-hex> (plan §4.1).
func blobPath(root string, id ChunkID) string {
	h := id.String()
	return filepath.Join(root, "chunks", h[0:2], h[2:4], h)
}

// blobDir returns the directory containing the blob file.
func blobDir(root string, id ChunkID) string {
	h := id.String()
	return filepath.Join(root, "chunks", h[0:2], h[2:4])
}
