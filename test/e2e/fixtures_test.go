package e2e_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

// -----------------------------------------------------------------------------
// Deterministic content + metadata. Fixtures are built from these constants so
// the expected merged-rootfs tree (below) can be computed independently of the
// ingest internals, straight from the same source-of-truth values.
// -----------------------------------------------------------------------------

// Fixed timestamps (nonzero nanos so mtime_ns round-trips for the cases that
// set it). Distinct per layer to make overwrite/merge visible if metadata was
// wrong.
var (
	t0 = time.Unix(1_600_000_000, 1000) // base layer
	t1 = time.Unix(1_700_000_000, 2000) // xattr file in base
	t2 = time.Unix(1_800_000_000, 3000) // upper layer
)

// Logical file contents. bigContent is 1.5 MiB -> two 1 MiB chunks (the chunker
// is 1 MiB), so block offsets 0 and 1<<20 are exercised and asserted.
var (
	smallContent  = []byte("hello world\n")
	bigContent    = makeBigContent(1_500_000)
	emptyContent  = []byte{}
	rmContent     = []byte("to-be-removed\n")
	keepLower     = []byte("lower-keep\n")
	keepUpper     = []byte("upper-keep-replaced\n")
	hlContent     = []byte("hardlinked content payload\n")
	xattrContent  = []byte("xattr body bytes\n")
	exeContent    = []byte("#!/bin/sh\necho hi\n")
	opaqueOld1    = []byte("o1\n")
	opaqueOld2    = []byte("o2\n")
	opaqueNew1    = []byte("n1\n")
	tcInner       = []byte("inner payload\n")
	tcUpper       = []byte("now a regular file\n")
	symLinkTarget = "a/b/c/small.txt"
)

// makeBigContent returns n bytes of deterministic, repeating-but-non-trivial
// content (so the two chunks differ, exercising block offsets).
func makeBigContent(n int) []byte {
	out := make([]byte, n)
	pat := []byte("DETERMINISTIC-BLOCK-PATTERN-")
	for i := 0; i < n; i++ {
		out[i] = pat[i%len(pat)]
	}
	return out
}

// tarEntry is a single entry in a synthesized layer tar.
type tarEntry struct {
	name     string // cleaned, rootfs-relative
	typeflag byte   // tar.TypeReg/TypeDir/TypeSymlink/TypeLink
	mode     int64
	uid, gid int
	mtime    time.Time
	body     []byte
	linkname string
	xattrs   map[string]string // emitted as PAX SCHILY.xattr.<k>=<v>
}

// file returns a regular-file tarEntry.
func file(name string, body []byte, mode int64, uid, gid int, mtime time.Time) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeReg, mode: mode, uid: uid, gid: gid, mtime: mtime, body: body}
}

// fileXattrs is file plus xattrs.
func fileXattrs(name string, body []byte, mode int64, uid, gid int, mtime time.Time, xa map[string]string) tarEntry {
	e := file(name, body, mode, uid, gid, mtime)
	e.xattrs = xa
	return e
}

func dirE(name string, mode int64, uid, gid int, mtime time.Time) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeDir, mode: mode, uid: uid, gid: gid, mtime: mtime}
}

func sym(name, target string, uid, gid int) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeSymlink, mode: 0o777, uid: uid, gid: gid, linkname: target}
}

func hardlink(name, target string) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeLink, linkname: target}
}

// whiteoutExplicit emits an explicit .wh.<name> whiteout entry (size 0).
func whiteoutExplicit(name string) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeReg, mode: 0, body: nil}
}

// opaqueMark emits an opaque .wh..wh..opq entry for a directory.
func opaqueMark(name string) tarEntry {
	return tarEntry{name: name, typeflag: tar.TypeDir, mode: 0o755}
}

// baseLayerEntries is the lower layer. It is shared across all layout variants.
func baseLayerEntries() []tarEntry {
	return []tarEntry{
		// 3+-deep directory hierarchy.
		dirE("a", 0o755, 0, 0, t0),
		dirE("a/b", 0o755, 0, 0, t0),
		dirE("a/b/c", 0o755, 0, 0, t0),

		// small regular file + >1 MiB multi-block file at the deep level.
		file("a/b/c/small.txt", smallContent, 0o644, 0, 0, t0),
		file("a/b/c/big.bin", bigContent, 0o640, 1000, 1000, t0),

		// empty file (exercises zero-block reconstruction).
		file("empty", emptyContent, 0o644, 0, 0, t0),

		// file that gets removed by an explicit whiteout in the upper layer.
		file("rm.txt", rmContent, 0o644, 0, 0, t0),

		// file overwritten in the upper layer with different content.
		file("keep.txt", keepLower, 0o644, 0, 0, t0),

		// hardlinked pair within this layer (orig first, alias second).
		dirE("hl", 0o755, 0, 0, t0),
		file("hl/orig", hlContent, 0o644, 0, 0, t0),
		hardlink("hl/alias", "hl/orig"),

		// symlink (target preserved in manifest, content not chunked).
		sym("link", symLinkTarget, 0, 0),

		// xattr-bearing file with non-0644 mode and non-root owner + nonzero ns.
		fileXattrs("xattr.bin", xattrContent, 0o600, 33, 33, t1, map[string]string{
			"user.test": "value",
		}),

		// non-0644 mode executable file.
		file("exe.sh", exeContent, 0o755, 0, 0, t0),

		// directory opaque-cleared by the upper layer; base adds two children.
		dirE("opaque", 0o755, 0, 0, t0),
		file("opaque/old1", opaqueOld1, 0o644, 0, 0, t0),
		file("opaque/old2", opaqueOld2, 0o644, 0, 0, t0),

		// directory whose type changes to a file in the upper layer.
		dirE("typechange", 0o755, 0, 0, t0),
		file("typechange/inner", tcInner, 0o644, 0, 0, t0),
	}
}

// upperLayerEntries is the upper layer. Shared across all layout variants.
func upperLayerEntries() []tarEntry {
	return []tarEntry{
		// overwrite a lower file with different content.
		file("keep.txt", keepUpper, 0o644, 0, 0, t2),

		// explicit whiteout of a lower file.
		whiteoutExplicit(".wh.rm.txt"),

		// opaque whiteout clears lower dir, then upper adds a single child.
		dirE("opaque", 0o755, 0, 0, t2),
		file("opaque/new1", opaqueNew1, 0o644, 0, 0, t2),
		opaqueMark("opaque/.wh..wh..opq"),

		// type change: file replaces a lower directory.
		file("typechange", tcUpper, 0o644, 0, 0, t2),

		// cross-layer hardlink: upper layer links to a base-layer regular
		// file (a/b/c/small.txt). Resolves at merge time into a shared inode
		// in the merged manifest; the upper layer's provenance manifest
		// carries a symbolic Hardlink entry for it (it cannot see the
		// target inside its own layer tar).
		hardlink("xlink", "a/b/c/small.txt"),
	}
}

// buildRawLayerTar renders entries as a plain (uncompressed) tar stream.
func buildRawLayerTar(entries []tarEntry) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	sortEntriesStable(entries)
	for i := range entries {
		hdr := buildTarHeader(&entries[i])
		if err := tw.WriteHeader(hdr); err != nil {
			panic(fmt.Sprintf("tar write header %q: %v", entries[i].name, err))
		}
		if len(entries[i].body) > 0 {
			if _, err := tw.Write(entries[i].body); err != nil {
				panic(fmt.Sprintf("tar write body %q: %v", entries[i].name, err))
			}
		}
	}
	if err := tw.Close(); err != nil {
		panic(err)
	}
	return buf.Bytes()
}

// sortEntriesStable orders entries so parents precede children and hardlink
// targets precede the links that reference them (so the walker resolves links
// in-layer). It is deterministic to keep fixtures reproducible.
func sortEntriesStable(entries []tarEntry) {
	idx := make([]int, len(entries))
	for i := range entries {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool {
		ea, eb := entries[idx[a]], entries[idx[b]]
		// Directories before their children by slash-prefix.
		prefix := func(e tarEntry) bool { return e.typeflag == tar.TypeDir }
		if prefix(ea) && !prefix(eb) {
			return true
		}
		if prefix(eb) && !prefix(ea) {
			return false
		}
		// Hardlink targets (TypeReg) before hardlinks (TypeLink) with same base.
		if ea.typeflag == tar.TypeLink && eb.typeflag != tar.TypeLink {
			return false
		}
		if eb.typeflag == tar.TypeLink && ea.typeflag != tar.TypeLink {
			return true
		}
		return ea.name < eb.name
	})
	out := make([]tarEntry, len(entries))
	for i := range idx {
		out[i] = entries[idx[i]]
	}
	copy(entries, out)
}

func buildTarHeader(e *tarEntry) *tar.Header {
	h := &tar.Header{
		Name:       e.name,
		Mode:       e.mode,
		Uid:        e.uid,
		Gid:        e.gid,
		Typeflag:   e.typeflag,
		Size:       int64(len(e.body)),
		ModTime:    e.mtime,
		Linkname:   e.linkname,
		Format:     tar.FormatPAX,
		PAXRecords: map[string]string{},
	}
	for k, v := range e.xattrs {
		h.PAXRecords["SCHILY.xattr."+k] = v
	}
	return h
}

// -----------------------------------------------------------------------------
// Layer compression (gzip / zstd / raw).
// -----------------------------------------------------------------------------

func gzipLayer(raw []byte) []byte {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	if _, err := gz.Write(raw); err != nil {
		panic(err)
	}
	if err := gz.Close(); err != nil {
		panic(err)
	}
	return buf.Bytes()
}

func zstdLayer(raw []byte) []byte {
	enc, err := zstd.NewWriter(nil)
	if err != nil {
		panic(err)
	}
	defer enc.Close()
	out := enc.EncodeAll(raw, nil)
	return out
}

// compression describes how a layer blob is to be stored in an OCI image.
type compression int

const (
	compGzip compression = iota
	compZstd
	compRaw
)

func (c compression) ociMediaType() string {
	switch c {
	case compGzip:
		return v1.MediaTypeImageLayerGzip
	case compZstd:
		return "application/vnd.oci.image.layer.v1.tar+zstd"
	default:
		return v1.MediaTypeImageLayer
	}
}

func (c compression) apply(raw []byte) []byte {
	switch c {
	case compGzip:
		return gzipLayer(raw)
	case compZstd:
		return zstdLayer(raw)
	default:
		return raw
	}
}

// -----------------------------------------------------------------------------
// Outer-tarball assembly (OCI and legacy docker-save).
// -----------------------------------------------------------------------------

// digestHex returns the sha256 hex of b.
func digestHex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ociConfigJSON is a minimal but valid OCI image config blob. Ingest parses
// only the manifest pointing at it, so its contents need only be JSON.
func ociConfigJSON() []byte {
	cfg := map[string]any{
		"architecture": "amd64",
		"os":           "linux",
		"created":      "2020-01-01T00:00:00Z",
		"config":       map[string]any{},
		"rootfs": map[string]any{
			"type":     "layers",
			"diff_ids": []string{},
		},
	}
	b, err := json.Marshal(cfg)
	if err != nil {
		panic(err)
	}
	return b
}

// buildOuterTar writes entries in order into an outer tarball.
func buildOuterTar(entries []tarOutEntry) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for i := range entries {
		e := &entries[i]
		h := &tar.Header{
			Name:     e.name,
			Mode:     0o644,
			Typeflag: tar.TypeReg,
			Size:     int64(len(e.body)),
			Format:   tar.FormatPAX,
		}
		if e.isDir {
			h.Typeflag = tar.TypeDir
			h.Size = 0
		}
		if err := tw.WriteHeader(h); err != nil {
			panic(err)
		}
		if len(e.body) > 0 {
			if _, err := tw.Write(e.body); err != nil {
				panic(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		panic(err)
	}
	return buf.Bytes()
}

type tarOutEntry struct {
	name  string
	body  []byte
	isDir bool
}

// buildOCITarball assembles an OCI-layout image from compressed layer blobs.
// layerComps[i] gives the compression of layer i (lower->upper order).
func buildOCITarball(layerBlobs [][]byte, layerComps []compression) []byte {
	config := ociConfigJSON()
	cfgHex := digestHex(config)
	cfgPath := "blobs/sha256/" + cfgHex

	layerPaths := make([]string, len(layerBlobs))
	for i, lb := range layerBlobs {
		layerPaths[i] = "blobs/sha256/" + digestHex(lb)
	}

	layersJSON := make([]map[string]any, len(layerBlobs))
	for i := range layerBlobs {
		layersJSON[i] = map[string]any{
			"mediaType": layerComps[i].ociMediaType(),
			"digest":    "sha256:" + digestHex(layerBlobs[i]),
			"size":      len(layerBlobs[i]),
		}
	}
	manifest := map[string]any{
		"schemaVersion": 2,
		"mediaType":     v1.MediaTypeImageManifest,
		"config": map[string]any{
			"mediaType": v1.MediaTypeImageConfig,
			"digest":    "sha256:" + cfgHex,
			"size":      len(config),
		},
		"layers": layersJSON,
	}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		panic(err)
	}
	manifestPath := "blobs/sha256/" + digestHex(manifestBytes)

	index := map[string]any{
		"schemaVersion": 2,
		"manifests": []map[string]any{
			{
				"mediaType": v1.MediaTypeImageManifest,
				"digest":    "sha256:" + digestHex(manifestBytes),
				"size":      len(manifestBytes),
			},
		},
	}
	indexBytes, err := json.Marshal(index)
	if err != nil {
		panic(err)
	}
	layout := map[string]any{"imageLayoutVersion": "1.0"}
	layoutBytes, err := json.Marshal(layout)
	if err != nil {
		panic(err)
	}

	entries := []tarOutEntry{
		{name: "oci-layout", body: layoutBytes},
		{name: "index.json", body: indexBytes},
		{name: cfgPath, body: config},
		{name: manifestPath, body: manifestBytes},
	}
	for i, lb := range layerBlobs {
		entries = append(entries, tarOutEntry{name: layerPaths[i], body: lb})
	}
	return buildOuterTar(entries)
}

// buildLegacyTarball assembles a legacy `docker save` bundle from raw (or any)
// layer tar blobs. Layers are stored verbatim (docker-save conventionally
// leaves them raw; raw is sniffed as CompRaw by ingest).
func buildLegacyTarball(layerBlobs [][]byte) []byte {
	config := ociConfigJSON()
	cfgHex := digestHex(config)
	cfgName := cfgHex + ".json"

	tags := []string{"e2e:latest"}
	layerPaths := make([]string, len(layerBlobs))
	for i, lb := range layerBlobs {
		layerPaths[i] = digestHex(lb) + "/layer.tar"
	}

	manifest := []map[string]any{
		{
			"Config":   cfgName,
			"RepoTags": tags,
			"Layers":   layerPaths,
		},
	}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		panic(err)
	}

	entries := []tarOutEntry{
		{name: "manifest.json", body: manifestBytes},
		{name: cfgName, body: config},
	}
	for i, lb := range layerBlobs {
		entries = append(entries, tarOutEntry{name: layerPaths[i], body: lb})
	}
	return buildOuterTar(entries)
}

// makeImageTarball builds the 2-layer image in a given layout/compression.
func makeImageTarball(layout string, comp compression) []byte {
	base := buildRawLayerTar(baseLayerEntries())
	upper := buildRawLayerTar(upperLayerEntries())
	layers := [][]byte{comp.apply(base), comp.apply(upper)}
	// Legacy uses raw layer tars (docker-save convention); ignore comp.
	if layout == "legacy" {
		rawLayers := [][]byte{base, upper}
		return buildLegacyTarball(rawLayers)
	}
	comps := []compression{comp, comp}
	return buildOCITarball(layers, comps)
}

// sha256Hex is a small helper for assertions.
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// writeTempTarball writes b to a fresh file under t.TempDir() and returns its
// path. The caller does not need to remove it (t.TempDir is cleaned up).
func writeTempTarball(t *testing.T, b []byte) string {
	t.Helper()
	dir := t.TempDir()
	p := dir + "/image.tar"
	if err := osWriteFile(p, b, 0o644); err != nil {
		t.Fatalf("write tarball: %v", err)
	}
	return p
}

// osWriteFile is a thin local wrapper around os.WriteFile so the rest of the
// fixture file does not need its own stdlib import dance.
func osWriteFile(path string, b []byte, perm os.FileMode) error {
	return os.WriteFile(path, b, perm)
}
