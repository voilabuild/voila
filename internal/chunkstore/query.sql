-- name: ChunkExists :one
SELECT 1 as exists_flag FROM chunks WHERE id = ?;

-- name: GetChunkCompAlgo :one
SELECT comp_algo FROM chunks WHERE id = ?;

-- name: GetChunkStat :one
SELECT logical_len, stored_len FROM chunks WHERE id = ?;

-- name: InsertChunk :exec
INSERT INTO chunks (id, logical_len, stored_len, comp_algo, created_ns, last_access_ns) VALUES (?, ?, ?, ?, ?, ?);

-- name: ListChunkIDs :many
SELECT id FROM chunks;

-- name: DeleteChunk :exec
DELETE FROM chunks WHERE id = ?;
