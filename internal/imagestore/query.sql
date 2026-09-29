-- name: GetImageByRef :one
SELECT ref, image_digest, merged_root_manifest_chunk, total_size, chunk_count, ingested_ns, last_used_ns FROM images WHERE ref = ?;

-- name: ListImages :many
SELECT ref, image_digest, merged_root_manifest_chunk, total_size, chunk_count, ingested_ns, last_used_ns FROM images ORDER BY ref ASC;

-- name: UpsertImage :exec
INSERT INTO images (ref, image_digest, merged_root_manifest_chunk, total_size, chunk_count, ingested_ns, last_used_ns)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(ref) DO UPDATE SET
  image_digest=excluded.image_digest,
  merged_root_manifest_chunk=excluded.merged_root_manifest_chunk,
  total_size=excluded.total_size,
  chunk_count=excluded.chunk_count,
  ingested_ns=excluded.ingested_ns,
  last_used_ns=excluded.last_used_ns;

-- name: DeleteImage :exec
DELETE FROM images WHERE ref = ?;

-- name: CountLayers :one
SELECT COUNT(*) FROM layers;

-- name: GetLayerChunk :one
SELECT manifest_chunk FROM layers WHERE oci_digest = ?;

-- name: UpsertLayer :exec
INSERT INTO layers (oci_digest, manifest_chunk, created_ns) VALUES (?, ?, ?)
ON CONFLICT(oci_digest) DO UPDATE SET manifest_chunk=excluded.manifest_chunk;

-- name: ListLayers :many
SELECT oci_digest, manifest_chunk FROM layers;

-- name: DeleteLayer :exec
DELETE FROM layers WHERE oci_digest = ?;
