package chunkstore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"lukechampine.com/blake3"

	_ "modernc.org/sqlite"
)

// LocalStore is a content-addressed chunk store backed by on-disk blobs and a
// sqlite index. It is safe for concurrent use by multiple goroutines.
type LocalStore struct {
	root string
	db   *sql.DB
	q    *Queries

	mu sync.Mutex
}

// OpenLocal opens (creating if necessary) a LocalStore at root.
func OpenLocal(root string) (*LocalStore, error) {
	for _, sub := range []string{"chunks"} {
		if err := os.MkdirAll(filepath.Join(root, sub), 0o755); err != nil {
			return nil, err
		}
	}
	dbPath := filepath.Join(root, "index.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}
	// modernc sqlite is happiest with a single writer connection; the mutex
	// below guards writes, but setting this also serializes across any stray
	// reader/write races at the driver level.
	db.SetMaxOpenConns(1)
	// WAL + synchronous=NORMAL: commits append to the write-ahead log and
	// fsync only at checkpoints instead of per transaction. The default
	// rollback-journal mode fsyncs every INSERT, which put ~8ms of forced
	// disk wait on every chunk Put (measured: 25k-chunk push = 3m34s).
	// Durability posture is in plan §12: a crash may lose the most recent
	// index rows (leaving orphaned blobs, reclaimed by gc), never corrupt.
	var journalMode string
	if err := db.QueryRow(`PRAGMA journal_mode=WAL`).Scan(&journalMode); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("chunkstore: enable WAL: %w", err)
	}
	if _, err := db.Exec(`PRAGMA synchronous=NORMAL`); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("chunkstore: set synchronous: %w", err)
	}
	if _, err := db.Exec(schemaSQL); err != nil {
		_ = db.Close()
		return nil, err
	}

	return &LocalStore{
		root: root,
		db:   db,
		q:    New(db),
	}, nil
}

const schemaSQL = `
CREATE TABLE IF NOT EXISTS chunks (
	id           BLOB PRIMARY KEY,
	logical_len  INTEGER NOT NULL,
	stored_len   INTEGER NOT NULL,
	comp_algo    INTEGER NOT NULL,
	created_ns   INTEGER NOT NULL,
	last_access_ns INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_last_access ON chunks(last_access_ns);
`

// Close closes the underlying database.
func (s *LocalStore) Close() error {
	return s.db.Close()
}

// Put writes buf to the store, returning its ChunkID. It is idempotent: a
// repeated Put of identical bytes returns the existing chunk's id without
// rewriting the blob.
func (s *LocalStore) Put(buf []byte) (ChunkID, error) {
	id := hash(buf)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Fast path: already indexed.
	if _, err := s.q.ChunkExists(context.Background(), id[:]); err == nil {
		return id, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return ChunkID{}, err
	}

	stored, algo := encode(buf)

	dst := blobPath(s.root, id)
	if err := os.MkdirAll(blobDir(s.root, id), 0o755); err != nil {
		return ChunkID{}, err
	}
	// Atomic write: temp file in the same directory, then rename.
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".tmp-*")
	if err != nil {
		return ChunkID{}, err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err := tmp.Write(stored); err != nil {
		cleanup()
		return ChunkID{}, err
	}
	// No fsync on the blob (plan §12 durability posture): content-addressed
	// data self-verifies — a torn blob after a crash fails its BLAKE3 check
	// on Get (loud error, never silent corruption) and is recreatable by
	// re-ingest or registry re-fetch. The fsync was ~half the per-chunk
	// write cost on the ingest/push path.
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return ChunkID{}, err
	}
	if err := os.Rename(tmpName, dst); err != nil {
		_ = os.Remove(tmpName)
		return ChunkID{}, err
	}

	now := time.Now().UnixNano()
	err = s.q.InsertChunk(context.Background(), InsertChunkParams{
		ID:           id[:],
		LogicalLen:   int64(len(buf)),
		StoredLen:    int64(len(stored)),
		CompAlgo:     int64(algo),
		CreatedNs:    now,
		LastAccessNs: now,
	})
	if err != nil {
		// Index insert failed; remove the blob so we don't leak.
		_ = os.Remove(dst)
		return ChunkID{}, err
	}
	return id, nil
}

// Get returns the raw (uncompressed) bytes for id, or ErrNotFound.
func (s *LocalStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	stored, algo, err := s.GetStored(id)
	if err != nil {
		return nil, err
	}
	decoded, err := decode(stored, algo)
	if err != nil {
		return nil, &integrityErr{id: id, cause: err}
	}
	// Re-hash and verify against the id. The stored bytes are
	// content-addressed by the RAW hash, so a torn or swapped blob is caught
	// here (loud error, never silent corruption).
	got := hash(decoded)
	if got != id {
		return nil, &integrityErr{id: id, cause: errors.New("hash mismatch")}
	}
	// NOTE: last_access_ns is deliberately NOT updated here. v0.1 has no LRU
	// (deletion is GC-only, plan §4.3), and a per-Get sqlite UPDATE puts a
	// synchronous write on the hot read path — measured as a large fraction of
	// FUSE read latency. Phase 1's CachedStore owns access tracking.
	return decoded, nil
}

// GetStored returns the on-disk (possibly zstd-compressed) bytes for id
// along with the compression algo (compRaw / compZstd). It is the wire-ideal
// form: `voila push` sends these bytes verbatim with a Content-Encoding header
// so the registry decompresses server-side, avoiding the bandwidth waste of
// round-tripping raw bytes that were stored compressed. The caller MUST NOT
// assume the returned bytes hash to id — the id is the BLAKE3 of the RAW
// (decompressed) content; the registry verifies after decompression.
func (s *LocalStore) GetStored(id ChunkID) (stored []byte, algo int, err error) {
	a, err := s.q.GetChunkCompAlgo(context.Background(), id[:])
	if errors.Is(err, sql.ErrNoRows) {
		return nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	path := blobPath(s.root, id)
	raw, rerr := os.ReadFile(path)
	if rerr != nil {
		return nil, 0, rerr
	}
	return raw, int(a), nil
}

// Stat returns metadata for id without triggering any fetch.
func (s *LocalStore) Stat(id ChunkID) (ChunkMeta, bool) {
	row, err := s.q.GetChunkStat(context.Background(), id[:])
	if errors.Is(err, sql.ErrNoRows) {
		return ChunkMeta{}, false
	}
	if err != nil {
		return ChunkMeta{}, false
	}
	return ChunkMeta{LogicalLen: uint64(row.LogicalLen), StoredLen: uint64(row.StoredLen)}, true
}

// GC removes every indexed chunk not present in reachable, deleting both the
// index row and the blob file. It returns the number of chunks removed.
func (s *LocalStore) GC(reachable map[ChunkID]struct{}) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	ids, err := s.q.ListChunkIDs(context.Background())
	if err != nil {
		return 0, err
	}
	var toRemove []ChunkID
	for _, b := range ids {
		var id ChunkID
		copy(id[:], b)
		if _, ok := reachable[id]; !ok {
			toRemove = append(toRemove, id)
		}
	}

	removed := 0
	for _, id := range toRemove {
		if err := s.q.DeleteChunk(context.Background(), id[:]); err != nil {
			return removed, err
		}
		_ = os.Remove(blobPath(s.root, id))
		removed++
	}
	return removed, nil
}

// Count returns the number of indexed chunks and their total stored
// (on-disk) bytes. Used by `voila images prune` to size its warning.
func (s *LocalStore) Count() (n int, bytes uint64, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(stored_len), 0) FROM chunks`).Scan(&n, &bytes); err != nil {
		return 0, 0, fmt.Errorf("chunkstore: count: %w", err)
	}
	return n, bytes, nil
}

// PruneAll removes EVERY chunk in the store: all index rows and all blob
// files, plus any orphaned blobs or stale temp files sitting under <root>/chunks
// that are no longer indexed (removing the whole directory sweeps those too,
// which per-blob GC cannot). It returns the number of index rows removed and
// the sum of their stored_len bytes. The store remains open and usable after
// PruneAll (the chunks/ directory is recreated empty).
func (s *LocalStore) PruneAll() (removed int, bytes uint64, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(stored_len), 0) FROM chunks`).Scan(&removed, &bytes); err != nil {
		return 0, 0, fmt.Errorf("chunkstore: prune count: %w", err)
	}
	if _, err := s.db.Exec(`DELETE FROM chunks`); err != nil {
		return 0, 0, fmt.Errorf("chunkstore: prune index: %w", err)
	}
	chunksDir := filepath.Join(s.root, "chunks")
	if err := os.RemoveAll(chunksDir); err != nil {
		return removed, bytes, fmt.Errorf("chunkstore: prune blobs: %w", err)
	}
	if err := os.MkdirAll(chunksDir, 0o755); err != nil {
		return removed, bytes, fmt.Errorf("chunkstore: recreate chunks dir: %w", err)
	}
	return removed, bytes, nil
}

// hash returns the BLAKE3-256 of buf (the raw, uncompressed content). It is
// stateless and safe to call concurrently.
func hash(buf []byte) ChunkID {
	return ChunkID(blake3.Sum256(buf))
}

// integrityErr is returned when a stored blob fails verification on Get.
type integrityErr struct {
	id    ChunkID
	cause error
}

func (e *integrityErr) Error() string {
	return "chunkstore: corrupt blob " + e.id.String() + ": " + e.cause.Error()
}

func (e *integrityErr) Unwrap() error { return e.cause }
