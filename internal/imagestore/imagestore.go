// Package imagestore persists ImageManifest protobuf files plus a small
// sqlite index of ingested images, and resolves image refs / digest
// prefixes against that index. It is the pure-store half factored out of
// cmd/voila's package main (task 15): the CLI keeps flag parsing + the
// table/summary formatters + the gc guard; this package owns the on-disk
// layout (<root>/images.db + <root>/images/<refKey>.pb) and the resolution
// rules (exact-ref-then-digest-prefix, error text, auto-pull hook).
//
// imagestore DOES NOT import internal/registry: registry interaction is
// abstracted by the ManifestPuller interface so the package can be reused by
// the coming three-binary split without dragging the HTTP client in.
package imagestore

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"

	_ "modernc.org/sqlite"
)

// RefKey sanitizes an image ref into a filesystem-safe key, appending an
// 8-hex-char suffix of sha256(ref) so that refs which sanitize to the same
// string (e.g. "a/b" and "a_b") still map to distinct keys.
//
// Every character outside [a-zA-Z0-9._-] is replaced by '_'.
func RefKey(ref string) string {
	var b []byte
	for i := 0; i < len(ref); i++ {
		c := ref[i]
		switch {
		case c >= 'a' && c <= 'z',
			c >= 'A' && c <= 'Z',
			c >= '0' && c <= '9',
			c == '.', c == '_', c == '-':
			b = append(b, c)
		default:
			b = append(b, '_')
		}
	}
	sum := sha256.Sum256([]byte(ref))
	return string(b) + "-" + hex.EncodeToString(sum[:])[:8]
}

// Record mirrors a row in the images sqlite table.
type Record struct {
	Ref                string
	ImageDigest        []byte
	MergedRootManifest []byte
	TotalSize          int64
	ChunkCount         int64
	IngestedNS         int64
	LastUsedNS         int64
}

// Store persists ImageManifest protobuf files and a small sqlite index of
// ingested images. It is shared by the ingest and images subcommands. The
// zero value is NOT usable: open with Open.
type Store struct {
	Root   string // voila root
	ImgDir string // <root>/images
	DB     *sql.DB
	q      *Queries
}

// SchemaSQL is the DDL executed once per Open. Exported so callers (tests)
// can re-apply it on a freshly-truncated db without going through Open.
const SchemaSQL = `
CREATE TABLE IF NOT EXISTS images (
	ref                        TEXT    PRIMARY KEY,
	image_digest               BLOB    NOT NULL,
	merged_root_manifest_chunk BLOB    NOT NULL,
	total_size                 INTEGER NOT NULL,
	chunk_count                INTEGER NOT NULL,
	ingested_ns                INTEGER NOT NULL,
	last_used_ns               INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS layers (
	oci_digest     TEXT    NOT NULL PRIMARY KEY,
	manifest_chunk BLOB    NOT NULL,
	created_ns      INTEGER NOT NULL
);
`

// Open opens (creating if necessary) the metadata store rooted at root.
// The protobuf manifests live at <root>/images/, the sqlite db at
// <root>/images.db.
func Open(root string) (*Store, error) {
	imgDir := filepath.Join(root, "images")
	if err := os.MkdirAll(imgDir, 0o755); err != nil {
		return nil, err
	}
	dbPath := filepath.Join(root, "images.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(SchemaSQL); err != nil {
		_ = db.Close()
		return nil, err
	}
	return &Store{Root: root, ImgDir: imgDir, DB: db, q: New(db)}, nil
}

// Close closes the underlying database.
func (s *Store) Close() error {
	if s == nil {
		return nil
	}
	return s.DB.Close()
}

// ManifestPath returns the on-disk path of the ImageManifest pb file for ref.
// The file is named <refKey(ref)>.pb under the store's image dir.
func (s *Store) ManifestPath(ref string) string {
	return filepath.Join(s.ImgDir, RefKey(ref)+".pb")
}

// WriteManifestPB marshals the ImageManifest protobuf to <imgDir>/<key>.pb
// atomically (write-temp + rename).
func (s *Store) WriteManifestPB(ref string, im *voilapb.ImageManifest) error {
	data, err := proto.Marshal(im)
	if err != nil {
		return fmt.Errorf("marshal image manifest: %w", err)
	}
	path := s.ManifestPath(ref)
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}
	if _, err := tmp.Write(data); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return nil
}

// Upsert inserts or replaces a row keyed by ref.
func (s *Store) Upsert(r Record) error {
	if err := s.q.UpsertImage(context.Background(), UpsertImageParams{
		Ref:                     r.Ref,
		ImageDigest:             r.ImageDigest,
		MergedRootManifestChunk: r.MergedRootManifest,
		TotalSize:               r.TotalSize,
		ChunkCount:              r.ChunkCount,
		IngestedNs:              r.IngestedNS,
		LastUsedNs:              r.LastUsedNS,
	}); err != nil {
		return fmt.Errorf("upsert image row: %w", err)
	}
	return nil
}

// LookupRef returns the images.db row for ref (ok=false when the row is
// missing, e.g. an older ingest that predated the sqlite index). Used by
// cmdWorker's Resolve closure to fill ImageChunks / ImageBytes totals.
func (s *Store) LookupRef(ref string) (Record, bool) {
	img, err := s.q.GetImageByRef(context.Background(), ref)
	if err != nil {
		if err == sql.ErrNoRows {
			return Record{}, false
		}
		return Record{}, false
	}
	return Record{
		Ref:                img.Ref,
		ImageDigest:        img.ImageDigest,
		MergedRootManifest: img.MergedRootManifestChunk,
		TotalSize:          img.TotalSize,
		ChunkCount:         img.ChunkCount,
		IngestedNS:         img.IngestedNs,
		LastUsedNS:         img.LastUsedNs,
	}, true
}

// List returns all image records, sorted by ref.
func (s *Store) List() ([]Record, error) {
	images, err := s.q.ListImages(context.Background())
	if err != nil {
		return nil, err
	}
	out := make([]Record, 0, len(images))
	for _, img := range images {
		out = append(out, Record{
			Ref:                img.Ref,
			ImageDigest:        img.ImageDigest,
			MergedRootManifest: img.MergedRootManifestChunk,
			TotalSize:          img.TotalSize,
			ChunkCount:         img.ChunkCount,
			IngestedNS:         img.IngestedNs,
			LastUsedNS:         img.LastUsedNs,
		})
	}
	return out, nil
}

// DeleteImagesRow removes the images-table row keyed by ref. It does NOT
// touch the .pb manifest file (callers also Remove ManifestPath); the row
// is the index, the file is the artifact. Returns sql.ErrNoRows if no row
// was deleted (caller-visible so cmd can choose a clear not-found error).
func (s *Store) DeleteImagesRow(ref string) (sql.Result, error) {
	return s.DB.Exec(`DELETE FROM images WHERE ref = ?`, ref)
}

// CountLayerCacheRows returns the number of rows in the layers cache table.
// Used for hygiene assertions in tests (e.g. verifying gc drained the cache
// after collecting every manifest_chunk).
func (s *Store) CountLayerCacheRows() (int, error) {
	n, err := s.q.CountLayers(context.Background())
	if err != nil {
		return 0, err
	}
	return int(n), nil
}

// Lookup implements ingest.LayerCache: it returns the per-layer manifest
// chunk id previously Stored for the given OCI layer blob digest
// (canonical "sha256:<hex>"). ok is false when no row exists. Used by
// Ingest's cache pre-pass to skip the tar walk on a hit. The legacy
// docker-save layout carries no per-layer digest, so Lookup is never
// called for its layers — no row is ever inserted for them either (see
// Store).
func (s *Store) Lookup(ociDigest string) (chunkstore.ChunkID, bool) {
	raw, err := s.q.GetLayerChunk(context.Background(), ociDigest)
	if err != nil {
		return chunkstore.ChunkID{}, false
	}
	if len(raw) != len(chunkstore.ChunkID{}) {
		return chunkstore.ChunkID{}, false
	}
	var id chunkstore.ChunkID
	copy(id[:], raw)
	return id, true
}

// Store implements ingest.LayerCache: it records the (ociDigest, manifestChunk)
// pair so the next Ingest of a layer with the same blob digest hits the
// cache. It is idempotent. Only called for OCI-layout layers (the docker-save
// layout carries no per-layer digest; see ingest.Options.LayerCache docs).
func (s *Store) Store(ociDigest string, manifestChunk chunkstore.ChunkID) error {
	if err := s.q.UpsertLayer(context.Background(), UpsertLayerParams{
		OciDigest:     ociDigest,
		ManifestChunk: manifestChunk[:],
		CreatedNs:     time.Now().UnixNano(),
	}); err != nil {
		return fmt.Errorf("store layer cache row: %w", err)
	}
	return nil
}

// DropDeadLayerCacheRows removes layers rows whose manifest_chunk is no longer
// present in the chunk store (i.e. GC collected them). Called by `voila images
// gc` after store.GC so the cache does not keep returning chunks that
// VerifyTreeChunks would reject anyway (the rejection is the correctness
// guard; this cleanup is just hygiene so the table does not grow unbounded).
func (s *Store) DropDeadLayerCacheRows(store chunkstore.ChunkStore) (int, error) {
	rows, err := s.q.ListLayers(context.Background())
	if err != nil {
		return 0, err
	}
	var dead []string
	for _, r := range rows {
		if len(r.ManifestChunk) != len(chunkstore.ChunkID{}) {
			dead = append(dead, r.OciDigest)
			continue
		}
		var id chunkstore.ChunkID
		copy(id[:], r.ManifestChunk)
		if _, ok := store.Stat(id); !ok {
			dead = append(dead, r.OciDigest)
		}
	}
	removed := 0
	for _, d := range dead {
		if err := s.q.DeleteLayer(context.Background(), d); err != nil {
			return removed, err
		}
		removed++
	}
	return removed, nil
}

// PruneAll empties the images index and the layers cache table. It does NOT
// touch the .pb manifest files on disk (the CLI removes those separately, by
// globbing <imgDir>/*.pb so orphaned manifests are swept too). Returns the
// number of image rows removed.
func (s *Store) PruneAll() (images int, err error) {
	if err := ensureBuildCacheSchema(s); err != nil {
		return 0, fmt.Errorf("prune build cache schema: %w", err)
	}
	tx, err := s.DB.Begin()
	if err != nil {
		return 0, fmt.Errorf("prune images: begin: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	if err = tx.QueryRow(`SELECT COUNT(*) FROM images`).Scan(&images); err != nil {
		return 0, fmt.Errorf("prune images: count: %w", err)
	}
	if _, err = tx.Exec(`DELETE FROM images`); err != nil {
		return 0, fmt.Errorf("prune images: %w", err)
	}
	if _, err = tx.Exec(`DELETE FROM layers`); err != nil {
		return 0, fmt.Errorf("prune layer cache: %w", err)
	}
	if _, err = tx.Exec(`DELETE FROM build_cache`); err != nil {
		return 0, fmt.Errorf("prune build cache: %w", err)
	}
	if err = tx.Commit(); err != nil {
		return 0, fmt.Errorf("prune images: commit: %w", err)
	}
	return images, nil
}

// LoadImageManifest reads <imgDir>/<refKey(ref)>.pb and unmarshals it. The
// returned chunkstore.ChunkID is the merged-root manifest chunk id copied out
// of the parsed manifest (and is exactly 32 bytes long on success).
func (s *Store) LoadImageManifest(ref string) (*voilapb.ImageManifest, chunkstore.ChunkID, error) {
	// <refKey>.pb - we must recompose key here. The image's row in images.db
	// stores Ref verbatim; the on-disk pb filename is refKey(ref)+".pb".
	path := s.ManifestPath(ref)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, chunkstore.ChunkID{}, fmt.Errorf("read image manifest %q: %w", ref, err)
	}
	im := &voilapb.ImageManifest{}
	if err := proto.Unmarshal(data, im); err != nil {
		return nil, chunkstore.ChunkID{}, fmt.Errorf("unmarshal image manifest %q: %w", ref, err)
	}
	if len(im.GetMergedRootManifestChunk()) != len(chunkstore.ChunkID{}) {
		return nil, chunkstore.ChunkID{}, fmt.Errorf("image manifest %q: merged root manifest chunk is not 32 bytes", ref)
	}
	var cid chunkstore.ChunkID
	copy(cid[:], im.GetMergedRootManifestChunk())
	if im.GetImageRef() == "" {
		// Fall back so printed messages have something sensible.
		im.ImageRef = ref
	}
	return im, cid, nil
}
