package imagestore

import (
	"context"
	"fmt"
	"time"

	"voila/internal/chunkstore"
)

const buildCacheDDL = `
CREATE TABLE IF NOT EXISTS build_cache (
	cache_key       TEXT NOT NULL PRIMARY KEY,
	manifest_chunk  BLOB NOT NULL,
	config_chunk    BLOB NOT NULL,
	created_ns      INTEGER NOT NULL
);
`

func ensureBuildCacheSchema(s *Store) error {
	_, err := s.DB.Exec(buildCacheDDL)
	return err
}

// BuildCacheEntry is a cached instruction layer result.
type BuildCacheEntry struct {
	LayerManifest chunkstore.ChunkID
	ConfigChunk   chunkstore.ChunkID
}

// LookupBuildCache returns a cached layer for cacheKey. ok is false when absent.
func (s *Store) LookupBuildCache(cacheKey string) (BuildCacheEntry, bool) {
	if err := ensureBuildCacheSchema(s); err != nil {
		return BuildCacheEntry{}, false
	}
	var manifestRaw, configRaw []byte
	err := s.DB.QueryRowContext(context.Background(),
		`SELECT manifest_chunk, config_chunk FROM build_cache WHERE cache_key = ?`, cacheKey).
		Scan(&manifestRaw, &configRaw)
	if err != nil {
		return BuildCacheEntry{}, false
	}
	if len(manifestRaw) != len(chunkstore.ChunkID{}) || len(configRaw) != len(chunkstore.ChunkID{}) {
		return BuildCacheEntry{}, false
	}
	var layer, cfg chunkstore.ChunkID
	copy(layer[:], manifestRaw)
	copy(cfg[:], configRaw)
	return BuildCacheEntry{LayerManifest: layer, ConfigChunk: cfg}, true
}

// StoreBuildCache records a cache hit for cacheKey.
func (s *Store) StoreBuildCache(cacheKey string, layer, config chunkstore.ChunkID) error {
	if err := ensureBuildCacheSchema(s); err != nil {
		return err
	}
	_, err := s.DB.ExecContext(context.Background(),
		`INSERT OR REPLACE INTO build_cache (cache_key, manifest_chunk, config_chunk, created_ns) VALUES (?, ?, ?, ?)`,
		cacheKey, layer[:], config[:], time.Now().UnixNano())
	if err != nil {
		return fmt.Errorf("store build cache: %w", err)
	}
	return nil
}

// PruneBuildCache removes all build cache rows (called by images prune).
func (s *Store) PruneBuildCache() error {
	if err := ensureBuildCacheSchema(s); err != nil {
		return err
	}
	_, err := s.DB.Exec(`DELETE FROM build_cache`)
	return err
}
