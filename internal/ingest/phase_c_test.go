package ingest

import (
	"archive/tar"
	"bytes"
	"context"
	"fmt"
	"sync"
	"testing"

	"voila/internal/chunkstore"

	"lukechampine.com/blake3"
)

// memLayerCache is a tiny in-memory ingest.LayerCache for the Part C tests.
// It maps the OCI layer blob digest ("sha256:<hex>") to its per-layer
// per-layer manifest chunk id. Safe for concurrent use.
type memLayerCache struct {
	mu sync.Mutex
	m  map[string]chunkstore.ChunkID
}

func newMemLayerCache() *memLayerCache {
	return &memLayerCache{m: map[string]chunkstore.ChunkID{}}
}

func (c *memLayerCache) Lookup(digest string) (chunkstore.ChunkID, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	id, ok := c.m[digest]
	return id, ok
}

func (c *memLayerCache) Store(digest string, id chunkstore.ChunkID) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[digest] = id
	return nil
}

// countContentPutStore wraps a ChunkStore and counts how many times a watched
// content chunk id (the BLAKE3 of a known layer-file payload) is Put. This is
// the measurement seam for "a cache hit skips the tar walk entirely": on a
// hit, no content chunk is Put a second time.
type countContentPutStore struct {
	chunkstore.ChunkStore
	watch       chunkstore.ChunkID
	contentPuts int
}

func newCountContentPutStore(inner chunkstore.ChunkStore, watch chunkstore.ChunkID) *countContentPutStore {
	return &countContentPutStore{ChunkStore: inner, watch: watch}
}

func (s *countContentPutStore) Put(b []byte) (chunkstore.ChunkID, error) {
	id := chunkstore.ChunkID(blake3.Sum256(b))
	if id == s.watch {
		s.contentPuts++
	}
	return s.ChunkStore.Put(b)
}

// buildSingleLayerOCITarball builds an OCI-layout tarball with one layer
// whose body is the given (uncompressed) layer tar bytes. The image manifest,
// config blob, and index.json are synthesized and the layer is referenced by
// its sha256:<hex> digest so the cache key is the layer's OCI digest.
func buildSingleLayerOCITarball(t *testing.T, layerBytes []byte) []byte {
	t.Helper()
	manifestJSON, configPath, layerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar"},
		[][]byte{layerBytes}, nil)
	descs := []testIndexEntry{{
		platform:     "",
		manifestJSON: manifestJSON,
		configJSON:   []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`),
		configPath:   configPath,
		layerBlobs:   layerBlobs,
	}}
	return buildOCITar(t, descs)
}

// TestLayerCache_SecondIngestReusesLayer asserts that a second ingest of the
// same OCI tarball (same layer blob → same digest) is served entirely from
// the layer cache: LayersReused == 1, and the merged-root manifest chunk id
// is identical to the first ingest (deterministic).
func TestLayerCache_SecondIngestReusesLayer(t *testing.T) {
	store := newMemStore()
	cache := newMemLayerCache()

	layer := newTarBuilder().
		dir("usr", 0o755).
		file("usr/bin/sh", []byte("shebang"), 0o755).
		file("etc/hosts", []byte("127.0.0.1 localhost\n"), 0o644).bytes()
	tarBytes := buildSingleLayerOCITarball(t, layer)
	path := writeTempTarball(t, tarBytes)

	opts := Options{Platform: "linux/amd64", LayerCache: cache}
	ctx := context.Background()

	res1, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("first Ingest: %v", err)
	}
	if res1.LayersReused != 0 {
		t.Errorf("first ingest LayersReused=%d want 0", res1.LayersReused)
	}
	if len(res1.Layers) != 1 {
		t.Fatalf("first ingest Layers=%d want 1", len(res1.Layers))
	}
	if got := len(cache.m); got != 1 {
		t.Fatalf("cache should hold 1 layer, holds %d", got)
	}

	res2, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("second Ingest: %v", err)
	}
	if res2.LayersReused != 1 {
		t.Errorf("second ingest LayersReused=%d want 1 (cache hit)", res2.LayersReused)
	}
	if res2.MergedRootManifestChunk != res1.MergedRootManifestChunk {
		t.Errorf("merged root manifest chunk changed between cache-off and cache-on first/second: %s != %s",
			res1.MergedRootManifestChunk, res2.MergedRootManifestChunk)
	}
	if res2.Layers[0].RootManifestChunk != res1.Layers[0].RootManifestChunk {
		t.Errorf("per-layer manifest chunk changed: %s != %s",
			res1.Layers[0].RootManifestChunk, res2.Layers[0].RootManifestChunk)
	}
}

// TestLayerCache_HitSkipsContentPuts wraps the store to count how many times
// the cached layer's single content chunk is Put. On the first ingest it is
// Put exactly once (during WalkLayer); on the second ingest the cache hit
// skips the walk entirely, so the content chunk is NOT Put again (the wrapper
// is shared across both ingests so the contentPuts counter must remain 1).
func TestLayerCache_HitSkipsContentPuts(t *testing.T) {
	content := []byte("hello voila world — a unique content payload")
	// The single chunk the file maps to (content is < ChunkSize so one chunk).
	watch := chunkstore.ChunkID(blake3.Sum256(content))

	inner := newMemStore()
	store := newCountContentPutStore(inner, watch)
	cache := newMemLayerCache()

	layer := newTarBuilder().file("hello.txt", content, 0o644).bytes()
	tarBytes := buildSingleLayerOCITarball(t, layer)
	path := writeTempTarball(t, tarBytes)

	opts := Options{Platform: "linux/amd64", LayerCache: cache}
	ctx := context.Background()

	if _, err := Ingest(ctx, path, store, opts); err != nil {
		t.Fatalf("first Ingest: %v", err)
	}
	if store.contentPuts != 1 {
		t.Fatalf("first ingest contentPuts=%d want 1", store.contentPuts)
	}

	// Second ingest: cache hit must skip the walk → no content Put for the
	// file's chunk. The wrapper persists between calls, so contentPuts must
	// not grow.
	if _, err := Ingest(ctx, path, store, opts); err != nil {
		t.Fatalf("second Ingest: %v", err)
	}
	if store.contentPuts != 1 {
		t.Errorf("second ingest contentPuts grew to %d, want still 1 (cache hit should skip walk)", store.contentPuts)
	}
}

// TestLayerCache_CacheOffVsCacheOnMergedRootEqual ingests the same OCI
// tarball twice into two fresh stores — once cache-off (nil), once cache-on.
// By determinism, the merged-root manifest chunk ids must be IDENTICAL. This
// guards the round-trip equivalence property the spec calls out: the merged
// root does not depend on whether the layer was walked or served from the
// cache.
func TestLayerCache_CacheOffVsCacheOnMergedRootEqual(t *testing.T) {
	layer := newTarBuilder().
		dir("etc", 0o755).
		file("etc/conf", []byte("config payload"), 0o644).
		file("README", []byte("voila"), 0o644).bytes()
	tarBytes := buildSingleLayerOCITarball(t, layer)
	path := writeTempTarball(t, tarBytes)
	ctx := context.Background()

	// Cache-off ingest.
	storeOff := newMemStore()
	resOff, err := Ingest(ctx, path, storeOff, Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("cache-off Ingest: %v", err)
	}

	// Cache-on ingest into a fresh store with its own cache: the first
	// ingest walks (miss), so its merged root must match the cache-off root.
	storeOn := newMemStore()
	cacheOn := newMemLayerCache()
	resOn, err := Ingest(ctx, path, storeOn, Options{Platform: "linux/amd64", LayerCache: cacheOn})
	if err != nil {
		t.Fatalf("cache-on (first / miss) Ingest: %v", err)
	}
	if resOn.MergedRootManifestChunk != resOff.MergedRootManifestChunk {
		t.Fatalf("merged root mismatch cache-off %s != cache-on (miss) %s",
			resOff.MergedRootManifestChunk, resOn.MergedRootManifestChunk)
	}

	// Second ingest into the same store with the SAME cache now HITS.
	// LayersReused == 1 and the merged root must STILL equal the cache-off
	// root — the equality property holds whether the layer was walked or
	// served from the cache.
	resHit, err := Ingest(ctx, path, storeOn, Options{Platform: "linux/amd64", LayerCache: cacheOn})
	if err != nil {
		t.Fatalf("cache-on (hit) Ingest: %v", err)
	}
	if resHit.LayersReused != 1 {
		t.Errorf("cache-hit LayersReused=%d want 1", resHit.LayersReused)
	}
	if resHit.MergedRootManifestChunk != resOff.MergedRootManifestChunk {
		t.Errorf("cache-hit merged root %s != cache-off %s",
			resHit.MergedRootManifestChunk, resOff.MergedRootManifestChunk)
	}
}

// TestLayerCache_GCInvalidatedFallsBack simulates the gc case: a layer is
// ingested and cached, then the content chunk for the layer's file is
// physically removed from the store (as if gc collected it), but the manifest
// chunk remains. The next ingest's cache lookup hits, but VerifyTreeChunks
// fails (content chunk absent) and Ingest falls back to a fresh walk — no
// error, correct result, and the missing chunk is re-put.
func TestLayerCache_GCInvalidatedFallsBack(t *testing.T) {
	store := newMemStore()
	cache := newMemLayerCache()

	content := []byte("payload to be gc'd")
	layer := newTarBuilder().file("f", content, 0o644).bytes()
	tarBytes := buildSingleLayerOCITarball(t, layer)
	path := writeTempTarball(t, tarBytes)

	opts := Options{Platform: "linux/amd64", LayerCache: cache}
	ctx := context.Background()

	res1, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("first Ingest: %v", err)
	}
	if res1.LayersReused != 0 {
		t.Fatalf("first LayersReused=%d want 0", res1.LayersReused)
	}

	// Identify the content chunk of file "f" in the walked tree's first layer
	// and physically remove it from the memStore, simulating a gc reclaim.
	contentChunkID := chunkstore.ChunkID(blake3.Sum256(content))
	if _, ok := store.Stat(contentChunkID); !ok {
		t.Fatalf("content chunk %s not present after first ingest", contentChunkID)
	}
	delete(store.chunks, contentChunkID)

	// The cache STILL has the layer's manifest chunk (gc took content, not
	// the manifest). The next ingest's Lookup hits, DecodeTree succeeds
	// (manifest chunk still present), but VerifyTreeChunks must report false
	// (content chunk gone) → Ingest falls back to a fresh walk.
	res2, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("gc-invalidated cache ingest: %v", err)
	}
	// Fallback means the layer was walked, not served from cache.
	if res2.LayersReused != 0 {
		t.Errorf("after gc invalidated content, LayersReused=%d want 0 (should fall back to walk)", res2.LayersReused)
	}
	// The fresh walk re-put the content chunk.
	if _, ok := store.Stat(contentChunkID); !ok {
		t.Errorf("content chunk not re-put after fallback walk")
	}
	// Merged root identical: cache-fallback and cache-off paths must agree.
	store2 := newMemStore()
	resOff, err := Ingest(ctx, path, store2, Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("cache-off Ingest: %v", err)
	}
	if res2.MergedRootManifestChunk != resOff.MergedRootManifestChunk {
		t.Errorf("fallback merged root %s != cache-off %s",
			res2.MergedRootManifestChunk, resOff.MergedRootManifestChunk)
	}
}

// TestLayerCache_GCInvalidatedManifestFallsBack simulates gc collecting the
// cached manifest chunk itself. DecodeTree fails → Ingest falls back.
func TestLayerCache_GCInvalidatedManifestFallsBack(t *testing.T) {
	store := newMemStore()
	cache := newMemLayerCache()

	layer := newTarBuilder().file("f", []byte("payload"), 0o644).bytes()
	tarBytes := buildSingleLayerOCITarball(t, layer)
	path := writeTempTarball(t, tarBytes)

	opts := Options{Platform: "linux/amd64", LayerCache: cache}
	ctx := context.Background()

	res1, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("first Ingest: %v", err)
	}
	// Remove the manifest chunk for the cached layer.
	manifestChunk := res1.Layers[0].RootManifestChunk
	delete(store.chunks, manifestChunk)

	res2, err := Ingest(ctx, path, store, opts)
	if err != nil {
		t.Fatalf("gc-invalidated manifest ingest: %v", err)
	}
	if res2.LayersReused != 0 {
		t.Errorf("after gc invalidated manifest, LayersReused=%d want 0 (should fall back)", res2.LayersReused)
	}
	// The fallback re-walked and re-stored the per-layer manifest — it must
	// be present again and identical (deterministic).
	if _, ok := store.Stat(manifestChunk); !ok {
		t.Errorf("per-layer manifest chunk not re-stored after fallback")
	}
	if res2.Layers[0].RootManifestChunk != manifestChunk {
		t.Errorf("per-layer manifest chunk changed across fallback: %s != %s",
			res2.Layers[0].RootManifestChunk, manifestChunk)
	}
	if res2.MergedRootManifestChunk != res1.MergedRootManifestChunk {
		t.Errorf("merged root changed after fallback: %s != %s",
			res2.MergedRootManifestChunk, res1.MergedRootManifestChunk)
	}
}

// TestLayerCache_SharedBaseLayerReused: image A has one layer, image B has
// two layers sharing image A's base layer. After ingesting A, image B's
// ingest reports LayersReused=1 and produces the same merged root as a
// cache-disabled ingest of B. This is the cross-image memoization scenario
// the spec calls out (two-image pair sharing a base layer).
func TestLayerCache_SharedBaseLayerReused(t *testing.T) {
	baseLayer := newTarBuilder().
		dir("usr", 0o755).
		file("usr/bin/sh", []byte("shebang"), 0o755).
		file("etc/hosts", []byte("127.0.0.1 localhost\n"), 0o644).bytes()
	upperLayer := newTarBuilder().
		file("upper.txt", []byte("upper-only content"), 0o644).bytes()

	// Image A: a single base layer.
	aManifestJSON, aConfigPath, aLayerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar"},
		[][]byte{baseLayer}, nil)
	aDescs := []testIndexEntry{{
		platform:     "",
		manifestJSON: aManifestJSON,
		configJSON:   []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`),
		configPath:   aConfigPath,
		layerBlobs:   aLayerBlobs,
	}}
	aTar := buildOCITar(t, aDescs)
	aPath := writeTempTarball(t, aTar)

	// Image B: two layers, the FIRST of which is the SAME base layer (same
	// bytes → same OCI digest → same cache key). The second layer is unique
	// to B. Use distinct config blobs so the two images do not collide on
	// ref/digest assertions.
	bCfg := []byte(`{"architecture":"amd64","os":"linux","config":{"Env":["B=1"]},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	bManifestJSON, bConfigPath, bLayerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar"},
		[][]byte{baseLayer, upperLayer}, bCfg)
	bDescs := []testIndexEntry{{
		platform:     "",
		manifestJSON: bManifestJSON,
		configJSON:   bCfg,
		configPath:   bConfigPath,
		layerBlobs:   bLayerBlobs,
	}}
	bTar := buildOCITar(t, bDescs)
	bPath := writeTempTarball(t, bTar)

	ctx := context.Background()

	// Ingest image A then image B into the SAME store with the SAME cache.
	// The cache's stored chunk id is content-addressed WITHIN a store, so
	// sharing the cache across two stores would be meaningless; production
	// wires both to the same root.
	sharedStore := newMemStore()
	sharedCache := newMemLayerCache()
	if _, err := Ingest(ctx, aPath, sharedStore, Options{Platform: "linux/amd64", LayerCache: sharedCache}); err != nil {
		t.Fatalf("ingest A: %v", err)
	}
	if len(sharedCache.m) != 1 {
		t.Fatalf("after A cache holds %d layers, want 1", len(sharedCache.m))
	}

	// Ingest image B (same base layer as A) into the same store+cache. The
	// base layer must be served from the cache; the upper layer is unique
	// and walked. LayersReused must be 1.
	resB, err := Ingest(ctx, bPath, sharedStore, Options{Platform: "linux/amd64", LayerCache: sharedCache})
	if err != nil {
		t.Fatalf("ingest B: %v", err)
	}
	if resB.LayersReused != 1 {
		t.Errorf("B LayersReused=%d want 1 (shared base layer)", resB.LayersReused)
	}
	if len(resB.Layers) != 2 {
		t.Fatalf("B Layers=%d want 2", len(resB.Layers))
	}

	// 3) Same merged root as a cache-disabled ingest of B into a fresh
	//    store (the equality property).
	storeBOff := newMemStore()
	resBOff, err := Ingest(ctx, bPath, storeBOff, Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("cache-off ingest B: %v", err)
	}
	if resB.MergedRootManifestChunk != resBOff.MergedRootManifestChunk {
		t.Errorf("cache-on (1 reused) merged root %s != cache-off %s",
			resB.MergedRootManifestChunk, resBOff.MergedRootManifestChunk)
	}
}

// TestLayerCache_LegacyNotCached asserts the legacy docker-save layout never
// touches the cache: neither Lookup nor Store is called. This is the contract
// the spec calls out — legacy layers carry no trustworthy pre-stream digest,
// so the cache decision cannot be made before streaming.
func TestLayerCache_LegacyNotCached(t *testing.T) {
	layer := newTarBuilder().file("root.txt", []byte("hello"), 0o644).bytes()
	configJSON := []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	cfgHex := sha256Hex(configJSON)
	configName := cfgHex + ".json"
	layerName := cfgHex[:12] + "/layer.tar"

	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	write := func(name string, typ byte, body []byte, mode int64) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: mode, Typeflag: typ, Size: int64(len(body))}); err != nil {
			t.Fatal(err)
		}
		tw.Write(body)
	}
	write("manifest.json", tar.TypeReg, []byte(fmt.Sprintf(`[{"Config":%q,"RepoTags":["myimg:latest"],"Layers":[%q]}]`, configName, layerName)), 0o644)
	write(configName, tar.TypeReg, configJSON, 0o644)
	write(cfgHex[:12]+"/", tar.TypeDir, nil, 0o755)
	write(layerName, tar.TypeReg, layer, 0o644)
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	path := writeTempTarball(t, buf.Bytes())

	// Wrap a counting cache so we can assert no Lookup / Store calls.
	cache := &countingLayerCache{inner: newMemLayerCache()}
	store := newMemStore()
	ctx := context.Background()

	res, err := Ingest(ctx, path, store, Options{Platform: "linux/amd64", LayerCache: cache})
	if err != nil {
		t.Fatalf("legacy ingest: %v", err)
	}
	if res.LayersReused != 0 {
		t.Errorf("legacy LayersReused=%d want 0 (cache never consulted)", res.LayersReused)
	}
	if cache.lookups != 0 {
		t.Errorf("legacy ingest must not call LayerCache.Lookup, got %d call(s)", cache.lookups)
	}
	if cache.stores != 0 {
		t.Errorf("legacy ingest must not call LayerCache.Store, got %d call(s)", cache.stores)
	}
}

// countingLayerCache wraps a LayerCache and counts Lookup / Store calls.
type countingLayerCache struct {
	inner   LayerCache
	lookups int
	stores  int
}

func (c *countingLayerCache) Lookup(d string) (chunkstore.ChunkID, bool) {
	c.lookups++
	return c.inner.Lookup(d)
}

func (c *countingLayerCache) Store(d string, id chunkstore.ChunkID) error {
	c.stores++
	return c.inner.Store(d, id)
}

// TestVerifyTreeChunks reports true when every block chunk of a walked layer is
// present, false after a content chunk is removed (gc reclaimed it).
func TestVerifyTreeChunks(t *testing.T) {
	store := newMemStore()
	content := []byte("verify-tree-chunks payload")
	tree := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("d", 0o755).file("d/f", content, 0o644).symlink("l", "d/f")
	})
	if !VerifyTreeChunks(context.Background(), tree, store) {
		t.Error("VerifyTreeChunks=false want true (all chunks present)")
	}
	// Remove the single content chunk for d/f; VerifyTreeChunks must now fail.
	contentChunk := chunkstore.ChunkID(blake3.Sum256(content))
	delete(store.chunks, contentChunk)
	if VerifyTreeChunks(context.Background(), tree, store) {
		t.Error("VerifyTreeChunks=true want false (content chunk removed)")
	}
}

// TestVerifyTreeChunks_NilTreeStore guards the trivial nil cases.
func TestVerifyTreeChunks_NilTreeStore(t *testing.T) {
	if VerifyTreeChunks(context.Background(), nil, newMemStore()) {
		t.Error("nil tree → want false")
	}
	tree := buildLayerTree(t, newMemStore(), func(tb *tarBuilder) {
		tb.file("f", []byte("x"), 0o644)
	})
	if VerifyTreeChunks(context.Background(), tree, nil) {
		t.Error("nil store → want false")
	}
}

// TestLayerCache_WhiteoutLayerNeverCached: a layer that introduces whiteouts
// must NOT be stored in the layer cache — the Manifest proto does not carry
// whiteout/opaque markers, so a cache hit would silently drop the deletions
// at merge time (resurrected files). The whiteout-free layer in the same
// image IS cached.
func TestLayerCache_WhiteoutLayerNeverCached(t *testing.T) {
	baseLayer := newTarBuilder().
		file("keep.txt", []byte("keep"), 0o644).
		file("rm.txt", []byte("bye"), 0o644).bytes()
	upperLayer := newTarBuilder().
		file(".wh.rm.txt", nil, 0o644).bytes() // whiteout: delete rm.txt

	manifestJSON, configPath, layerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar"},
		[][]byte{baseLayer, upperLayer}, nil)
	tarBytes := buildOCITar(t, []testIndexEntry{{
		platform:     "",
		manifestJSON: manifestJSON,
		configJSON:   []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`),
		configPath:   configPath,
		layerBlobs:   layerBlobs,
	}})
	path := writeTempTarball(t, tarBytes)

	store := newMemStore()
	cache := newMemLayerCache()
	res, err := Ingest(context.Background(), path, store, Options{Platform: "linux/amd64", LayerCache: cache})
	if err != nil {
		t.Fatalf("Ingest: %v", err)
	}
	if res.Layers[1].WhiteoutsCount == 0 {
		t.Fatal("fixture broken: upper layer should carry a whiteout")
	}
	if len(cache.m) != 1 {
		t.Fatalf("cache holds %d layers, want 1 (only the whiteout-free base)", len(cache.m))
	}
	if _, ok := cache.m["sha256:"+sha256Hex(baseLayer)]; !ok {
		t.Error("base layer (whiteout-free) should be cached")
	}
	if _, ok := cache.m["sha256:"+sha256Hex(upperLayer)]; ok {
		t.Error("whiteout-bearing upper layer must NOT be cached")
	}
}
