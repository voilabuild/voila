package ingest

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/proto"

	"archive/tar"

	"google.golang.org/protobuf/proto"
)

// ----- merge tests -----

// buildLayerTree builds a LayerTree from a set of synthesized entries for the
// merge tests, using a tiny store so regular files get chunked. The add
// callback may use the tarBuilder helpers and may also call tb.write directly
// to emit raw whiteout/opaque entries.
func buildLayerTree(t *testing.T, store chunkstore.ChunkStore, add func(*tarBuilder)) *LayerTree {
	t.Helper()
	tb := newTarBuilder()
	add(tb)
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), store)
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}
	return res.Tree
}

func TestMerge_UpperFileReplacesLowerDir(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("etc", 0o755).file("etc/conf", []byte("l"), 0o644).file("etc/x", []byte("y"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("etc", []byte("I am a file now"), 0o600) // file replaces dir
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	n := merged.Lookup("etc")
	if n == nil || n.Type != NodeRegular {
		t.Fatalf("etc should be a regular file: %+v", n)
	}
	if n.Size != uint64(len("I am a file now")) {
		t.Errorf("etc size=%d", n.Size)
	}
	if merged.Lookup("etc/conf") != nil || merged.Lookup("etc/x") != nil {
		t.Error("lower dir children survived replacement by upper file")
	}
}

func TestMerge_UpperDirReplacesLowerFile(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("var", []byte("lower-file"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("var", 0o755).file("var/log", []byte("entry"), 0o644)
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	n := merged.Lookup("var")
	if n == nil || n.Type != NodeDir {
		t.Fatalf("var should be a dir: %+v", n)
	}
	if merged.Lookup("var/log") == nil {
		t.Error("var/log missing after replacement")
	}
	if merged.byPath["var"].Mode != 0o755 {
		t.Errorf("upper dir mode should win: got %o", merged.byPath["var"].Mode)
	}
}

func TestMerge_DirOverDirMergesChildrenUpperMetaWins(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("d", 0o755).file("d/keep", []byte("l"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("d", 0o700).file("d/add", []byte("u"), 0o644)
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	d := merged.Lookup("d")
	if d == nil || d.Type != NodeDir {
		t.Fatal("d missing")
	}
	if d.Mode != 0o700 {
		t.Errorf("upper dir mode should win: got %o", d.Mode)
	}
	if merged.Lookup("d/keep") == nil {
		t.Error("lower child d/keep dropped on dir-over-dir merge")
	}
	if merged.Lookup("d/add") == nil {
		t.Error("upper child d/add not added")
	}
}

func TestMerge_WhiteoutDropsSubtree(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("app", 0o755).
			file("app/a", []byte("a"), 0o644).
			dir("app/sub", 0o755).
			file("app/sub/b", []byte("b"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.write(&tar.Header{Name: ".wh.app", Typeflag: tar.TypeReg, Mode: 0o644, Size: 0}, nil)
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	if merged.Lookup("app") != nil || merged.Lookup("app/a") != nil || merged.Lookup("app/sub/b") != nil {
		t.Error("whiteout failed to drop app subtree")
	}
	if upper.WhiteoutsN != 1 {
		t.Errorf("whiteout count: %d", upper.WhiteoutsN)
	}
}

func TestMerge_OpaqueDropsLowerKeepsUpper(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("opt", 0o755).
			file("opt/low1", []byte("l1"), 0o644).
			file("opt/low2", []byte("l2"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("opt", 0o755).
			file("opt/up", []byte("u"), 0o644)
		tb.write(&tar.Header{Name: "opt/.wh..wh..opq", Typeflag: tar.TypeDir, Mode: 0o755}, nil)
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	if merged.Lookup("opt/low1") != nil || merged.Lookup("opt/low2") != nil {
		t.Error("opaque failed to drop lower children")
	}
	if merged.Lookup("opt/up") == nil {
		t.Error("opaque dropped upper's own child")
	}
}

func TestMerge_CrossLayerHardlinkResolves(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("orig.txt", []byte("payload"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.hardlink("link.txt", "orig.txt")
	})
	merged, err := MergeTrees([]*LayerTree{lower, upper})
	if err != nil {
		t.Fatal(err)
	}
	orig := merged.Lookup("orig.txt")
	link := merged.Lookup("link.txt")
	if orig == nil || link == nil {
		t.Fatal("both names must exist")
	}
	if orig != link {
		t.Fatalf("cross-layer hardlink does not share node: %p != %p", orig, link)
	}
	inodeOf, nlinkOf := AssignInodes(merged)
	inode := inodeOf[orig]
	if nlinkOf[inode] != 2 {
		t.Errorf("nlink got %d want 2", nlinkOf[inode])
	}
}

func TestMerge_PendingHardlinkMissingErrors(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("real", []byte("x"), 0o644)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.hardlink("alias", "nonexistent")
	})
	_, err := MergeTrees([]*LayerTree{lower, upper})
	if err == nil || !strings.Contains(err.Error(), "nonexistent") {
		t.Fatalf("want error naming missing target, got %v", err)
	}
}

func TestMerge_PendingHardlinkToNonRegularErrors(t *testing.T) {
	store := newMemStore()
	lower := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("d", 0o755)
	})
	upper := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.hardlink("alias", "d")
	})
	_, err := MergeTrees([]*LayerTree{lower, upper})
	if err == nil || !strings.Contains(err.Error(), "not a regular file") {
		t.Fatalf("want 'not a regular file' error, got %v", err)
	}
}

// ----- manifest tests -----

func TestManifest_DeterministicInodes(t *testing.T) {
	store := newMemStore()
	tree := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("a", 0o755).file("a/2", []byte("xx"), 0o644).file("a/1", []byte("yy"), 0o644)
		tb.file("z", []byte("zz"), 0o644)
	})
	inodeOf, nlinkOf := AssignInodes(tree)
	if inodeOf[tree.Root] != 1 {
		t.Errorf("root inode = %d, want 1", inodeOf[tree.Root])
	}
	a := inodeOf[tree.Lookup("a")]
	a1 := inodeOf[tree.Lookup("a/1")]
	a2 := inodeOf[tree.Lookup("a/2")]
	z := inodeOf[tree.Lookup("z")]
	if !(a == 2 && a1 == 3 && a2 == 4 && z == 5) {
		t.Errorf("inode assignment not sequential-sorted: a=%d a1=%d a2=%d z=%d", a, a1, a2, z)
	}
	if nlinkOf[a] != 1 || nlinkOf[z] != 1 {
		t.Errorf("nlink: a=%d z=%d", nlinkOf[a], nlinkOf[z])
	}
}

func TestManifest_DeterministicBytes(t *testing.T) {
	store := newMemStore()
	tree := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.dir("etc", 0o755).fileXattrs("etc/conf", []byte("v"),
			map[string]string{"user.x": "y"})
		tb.file("bin", []byte("payload"), 0o755)
		tb.symlink("link", "target")
		tb.device("dev/zero", tar.TypeChar, 1, 5)
	})
	_, b1, err := BuildManifest(tree, store)
	if err != nil {
		t.Fatal(err)
	}
	_, b2, err := BuildManifest(tree, store)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(b1, b2) {
		t.Errorf("non-deterministic: run1=%d bytes run2=%d bytes", len(b1), len(b2))
	}
	var got voilapb.Manifest
	if err := proto.Unmarshal(b1, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Dirs) == 0 {
		t.Error("no dirs in decoded manifest")
	}
}

func TestManifest_SplitExternalSubtrees(t *testing.T) {
	store := newMemStore()
	tb := newTarBuilder()
	const childDirs = 500
	const filesPerDir = 2
	for i := 0; i < childDirs; i++ {
		dir := fmt.Sprintf("d%04d", i)
		tb.dir(dir, 0o755)
		for j := 0; j < filesPerDir; j++ {
			tb.file(fmt.Sprintf("%s/f%d", dir, j), []byte(fmt.Sprintf("content-%d-%d", i, j)), 0o644)
		}
	}
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), store)
	if err != nil {
		t.Fatal(err)
	}
	tree := res.Tree

	root, data, err := BuildManifest(tree, store)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) > ManifestSplitThreshold {
		t.Fatalf("root manifest not under threshold after split: %d bytes", len(data))
	}
	if len(root.ExternalSubtrees) == 0 {
		t.Fatal("expected external_subtrees populated, got none")
	}
	// Reconstruct: collect dirs + files across root and every external child
	// manifest fetched from the store; verify counts match the original tree.
	totalDirs, totalFiles := reconstructCounts(root, store)
	wantDirs := 1 + childDirs
	wantFiles := childDirs * filesPerDir
	if totalDirs != wantDirs {
		t.Errorf("reconstructed dirs=%d want %d", totalDirs, wantDirs)
	}
	if totalFiles != wantFiles {
		t.Errorf("reconstructed files=%d want %d", totalFiles, wantFiles)
	}
	// Every external inode must appear as a root entry.
	rootDir := findDir(root, 1)
	if rootDir == nil {
		t.Fatal("root dir inode 1 missing")
	}
	if len(rootDir.Entries) != childDirs {
		t.Errorf("root entries=%d want %d", len(rootDir.Entries), childDirs)
	}
	for inode := range root.ExternalSubtrees {
		if !entryValueExists(rootDir, inode) {
			t.Errorf("external inode %d not referenced from root entries", inode)
		}
	}
}

func TestManifest_HardlinkSharesInodeAndNlink(t *testing.T) {
	store := newMemStore()
	tree := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("a", []byte("shared"), 0o644).hardlink("b", "a")
	})
	m, _, err := BuildManifest(tree, store)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Files) != 1 {
		t.Fatalf("expected one File entry for hardlink, got %d", len(m.Files))
	}
	for _, f := range m.Files {
		if f.Nlink != 2 {
			t.Errorf("File.nlink=%d want 2", f.Nlink)
		}
	}
	root := findDir(m, 1)
	inodeA := root.Entries["a"]
	inodeB := root.Entries["b"]
	if inodeA == 0 || inodeA != inodeB {
		t.Errorf("hardlink inodes a=%d b=%d (should match)", inodeA, inodeB)
	}
}

// TestManifest_PerLayerPendingHardlinksSymbolic: a per-layer manifest build
// of a tree containing a cross-layer (pending) hardlink must succeed and emit
// a symbolic Manifest.hardlinks entry (no File entry) for the pending inode,
// while the merged-mode build on the same tree errors. Inodes assigned by
// the sorted-path walk stay deterministic so two builds over the same tree
// yield identical bytes.
func TestManifest_PerLayerPendingHardlinksSymbolic(t *testing.T) {
	store := newMemStore()
	tree := buildLayerTree(t, store, func(tb *tarBuilder) {
		tb.file("orig.txt", []byte("payload"), 0o644)
		tb.hardlink("late.txt", "orig.txt")   // resolved in-layer
		tb.hardlink("xlink.txt", "ghostfile") // pending: target unseen
	})
	m, data, err := BuildLayerManifest(tree, store)
	if err != nil {
		t.Fatalf("BuildLayerManifest: %v", err)
	}
	root := findDir(m, 1)
	if root == nil {
		t.Fatal("root dir inode 1 missing")
	}
	xlinkInode, ok := root.Entries["xlink.txt"]
	if !ok {
		t.Fatal("xlink.txt Dir entry missing")
	}
	hl, ok := m.Hardlinks[xlinkInode]
	if !ok {
		t.Fatalf("no symbolic Hardlink entry for xlink inode %d", xlinkInode)
	}
	if hl.Inode != xlinkInode || hl.TargetPath != "ghostfile" {
		t.Errorf("Hardlink entry = %+v, want inode=%d target=ghostfile", hl, xlinkInode)
	}
	if _, hasFile := m.Files[xlinkInode]; hasFile {
		t.Error("xlink must NOT have a File entry in per-layer manifest")
	}
	// In-layer (resolved) hardlink still has one File with nlink=2.
	origInode := root.Entries["orig.txt"]
	lateInode := root.Entries["late.txt"]
	if origInode == 0 || origInode != lateInode {
		t.Errorf("in-layer hardlink inodes orig=%d late=%d (should match)", origInode, lateInode)
	}
	origFile, ok := m.Files[origInode]
	if !ok {
		t.Fatal("in-layer hardlink target missing File entry")
	}
	if origFile.Nlink != 2 {
		t.Errorf("in-layer hardlink nlink=%d want 2", origFile.Nlink)
	}

	// Deterministic bytes: rebuild and compare.
	_, data2, err := BuildLayerManifest(tree, store)
	if err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if !bytes.Equal(data, data2) {
		t.Errorf("per-layer manifest non-deterministic: %d vs %d bytes", len(data), len(data2))
	}

	// Merged-mode build on the same tree MUST error (pending reached merged).
	if _, _, err := BuildManifest(tree, store); err == nil {
		t.Error("BuildManifest (merged mode) should error on pending hardlink")
	}
}

// TestManifest_PerLayerDeterministicAcrossTrees: two freshly walked trees of
// the same tar shape (with a pending hardlink) must produce byte-identical
// per-layer manifests. Guards against accidental nondeterminism in inode
// assignment when byPath contains pending nodes.
func TestManifest_PerLayerDeterministicAcrossTrees(t *testing.T) {
	store := newMemStore()
	mk := func() []byte {
		tree := buildLayerTree(t, store, func(tb *tarBuilder) {
			tb.dir("d", 0o755).
				file("d/a", []byte("aaa"), 0o644).
				hardlink("d/z", "elsewhere/zzz")
		})
		_, data, err := BuildLayerManifest(tree, store)
		if err != nil {
			t.Fatalf("BuildLayerManifest: %v", err)
		}
		return data
	}
	d1, d2 := mk(), mk()
	if !bytes.Equal(d1, d2) {
		t.Errorf("two builds of the same per-layer tree disagree: %d vs %d bytes", len(d1), len(d2))
	}
}

// ----- layout-detection tests -----

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

type testLayerBlob struct {
	path  string
	bytes []byte
}

type testIndexEntry struct {
	platform     string
	manifestJSON []byte
	configJSON   []byte
	configPath   string
	layerBlobs   []testLayerBlob
}

// makeOCIManifest builds an image manifest JSON + config path + layer-blob
// descriptors for the given layers. configJSON may be nil for a default.
func makeOCIManifest(t *testing.T, layerMedia []string, layerBodies [][]byte, configJSON []byte) (manifestJSON []byte, configPath string, layerBlobs []testLayerBlob) {
	t.Helper()
	if configJSON == nil {
		configJSON = []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	}
	configHex := sha256Hex(configJSON)
	configPath = "blobs/sha256/" + configHex

	var layers []string
	for i, mt := range layerMedia {
		body := layerBodies[i]
		blobHex := sha256Hex(body)
		layerBlobs = append(layerBlobs, testLayerBlob{path: "blobs/sha256/" + blobHex, bytes: body})
		layers = append(layers,
			fmt.Sprintf(`{"mediaType":%q,"digest":"sha256:%s","size":%d}`,
				mt, blobHex, len(body)))
	}
	manifestJSON = []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[%s]}`,
		configHex, len(configJSON), strings.Join(layers, ",")))
	return
}

func buildOCITar(t *testing.T, descs []testIndexEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	write := func(name string, body []byte) {
		if err := tw.WriteHeader(&tar.Header{
			Name: name, Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(body)),
		}); err != nil {
			t.Fatal(err)
		}
		if len(body) > 0 {
			tw.Write(body)
		}
	}

	write("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))

	var indexEntries []string
	for _, d := range descs {
		manifestHex := sha256Hex(d.manifestJSON)
		write("blobs/sha256/"+manifestHex, d.manifestJSON)
		platform := ""
		if d.platform != "" {
			parts := strings.SplitN(d.platform, "/", 3)
			plat := `,"platform":{"os":"` + parts[0] + `","architecture":"` + parts[1] + `"`
			if len(parts) == 3 {
				plat += `,"variant":"` + parts[2] + `"`
			}
			plat += "}"
			platform = plat
		}
		indexEntries = append(indexEntries,
			`{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:`+manifestHex+`","size":`+fmt.Sprintf("%d", len(d.manifestJSON))+platform+`}`)
	}
	write("index.json", []byte(`{"schemaVersion":2,"manifests":[`+strings.Join(indexEntries, ",")+`]}`))

	written := map[string]bool{}
	for _, d := range descs {
		if !written[d.configPath] {
			write(d.configPath, d.configJSON)
			written[d.configPath] = true
		}
		for _, l := range d.layerBlobs {
			if !written[l.path] {
				write(l.path, l.bytes)
				written[l.path] = true
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func writeTempTarball(t *testing.T, body []byte) string {
	t.Helper()
	dir := t.TempDir()
	p := dir + "/image.tar"
	if err := os.WriteFile(p, body, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLayout_OCISingleManifestDetected(t *testing.T) {
	layer := newTarBuilder().file("root.txt", []byte("hello"), 0o644).bytes()
	manifestJSON, configPath, layerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar"},
		[][]byte{layer}, nil)
	descs := []testIndexEntry{{
		platform:     "",
		manifestJSON: manifestJSON,
		configJSON:   []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`),
		configPath:   configPath,
		layerBlobs:   layerBlobs,
	}}
	tarBytes := buildOCITar(t, descs)
	path := writeTempTarball(t, tarBytes)

	pl, err := parseLayout(path, &Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatal(err)
	}
	if pl.kind != layoutOCI {
		t.Errorf("kind=%v want OCI", pl.kind)
	}
	if len(pl.layers) != 1 {
		t.Fatalf("layers=%d want 1", len(pl.layers))
	}
	if pl.layers[0].path != layerBlobs[0].path {
		t.Errorf("layer path %q want %q", pl.layers[0].path, layerBlobs[0].path)
	}
	wantDigest, _ := hex.DecodeString(sha256Hex(manifestJSON))
	if !bytes.Equal(pl.imageDigest, wantDigest) {
		t.Errorf("imageDigest mismatch")
	}
}

func TestLayout_MultiPlatformSelectsCorrectly(t *testing.T) {
	sharedLayer := newTarBuilder().file("common", []byte("c"), 0o644).bytes()
	cfgA := []byte(`{"architecture":"amd64","os":"linux","config":{"Env":["A=1"]},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	cfgB := []byte(`{"architecture":"arm64","os":"linux","config":{"Env":["B=2"]},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	manA, cfgApath, lbA := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar"}, [][]byte{sharedLayer}, cfgA)
	manB, cfgBpath, lbB := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar+gzip"}, [][]byte{sharedLayer}, cfgB)

	descs := []testIndexEntry{
		{platform: "linux/amd64", manifestJSON: manA, configJSON: cfgA, configPath: cfgApath, layerBlobs: lbA},
		{platform: "linux/arm64", manifestJSON: manB, configJSON: cfgB, configPath: cfgBpath, layerBlobs: lbB},
	}
	tarBytes := buildOCITar(t, descs)
	path := writeTempTarball(t, tarBytes)

	pl, err := parseLayout(path, &Options{Platform: "linux/arm64"})
	if err != nil {
		t.Fatal(err)
	}
	wantDigest, _ := hex.DecodeString(sha256Hex(manB))
	if !bytes.Equal(pl.imageDigest, wantDigest) {
		t.Errorf("multi-platform selected wrong manifest; want arm64 digest")
	}
	if pl.configPath != cfgBpath {
		t.Errorf("selected config path %q want %q", pl.configPath, cfgBpath)
	}
	if len(pl.layers) != 1 || pl.layers[0].path != lbB[0].path {
		t.Errorf("selected layer path mismatch: %+v", pl.layers)
	}
	if pl.layers[0].hint != CompGzip {
		t.Errorf("hint for +gzip mediaType = %v, want CompGzip", pl.layers[0].hint)
	}

	_, err = parseLayout(path, &Options{Platform: "solaris/sparc"})
	if err == nil || !strings.Contains(err.Error(), "no image manifest for platform") {
		t.Fatalf("want platform-no-match error, got %v", err)
	}
}

func TestLayout_LegacyDetected(t *testing.T) {
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

	pl, err := parseLayout(path, &Options{})
	if err != nil {
		t.Fatal(err)
	}
	if pl.kind != layoutLegacy {
		t.Errorf("kind=%v want legacy", pl.kind)
	}
	if pl.ref != "myimg:latest" {
		t.Errorf("ref=%q want myimg:latest", pl.ref)
	}
	if pl.configPath != configName {
		t.Errorf("configPath=%q want %q", pl.configPath, configName)
	}
	if len(pl.layers) != 1 || pl.layers[0].path != layerName {
		t.Errorf("layer path %q want %q", pl.layers[0].path, layerName)
	}
	wantDigest, _ := hex.DecodeString(cfgHex)
	if !bytes.Equal(pl.imageDigest, wantDigest) {
		t.Error("legacy imageDigest mismatch")
	}
}

func TestLayout_UnknownErrors(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: "random", Typeflag: tar.TypeReg, Mode: 0o644, Size: 0})
	_ = tw.Close()
	path := writeTempTarball(t, buf.Bytes())
	_, err := parseLayout(path, &Options{})
	if err != ErrUnknownLayout {
		t.Fatalf("want ErrUnknownLayout, got %v", err)
	}
}

// ----- Ingest smoke test -----

func TestIngest_OCISmoke(t *testing.T) {
	layer := newTarBuilder().
		dir("usr", 0o755).
		file("usr/bin/sh", []byte("shebang"), 0o755).
		dir("etc", 0o755).
		file("etc/hosts", []byte("127.0.0.1 localhost\n"), 0o644).
		file("README", []byte("voila"), 0o644).bytes()

	manifestJSON, configPath, layerBlobs := makeOCIManifest(t,
		[]string{"application/vnd.oci.image.layer.v1.tar"},
		[][]byte{layer}, nil)
	descs := []testIndexEntry{{
		platform:     "",
		manifestJSON: manifestJSON,
		configJSON:   []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`),
		configPath:   configPath,
		layerBlobs:   layerBlobs,
	}}
	tarBytes := buildOCITar(t, descs)
	path := writeTempTarball(t, tarBytes)

	store := newMemStore()
	res, err := Ingest(context.Background(), path, store, Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("Ingest: %v", err)
	}
	if res == nil {
		t.Fatal("nil result")
	}
	if len(res.Layers) != 1 {
		t.Fatalf("Layers=%d want 1", len(res.Layers))
	}
	if res.MergedRootManifestChunk == (chunkstore.ChunkID{}) {
		t.Error("no merged root manifest chunk")
	}
	if res.ConfigChunk == (chunkstore.ChunkID{}) {
		t.Error("no config chunk")
	}
	rootBlob, err := store.Get(context.Background(), res.MergedRootManifestChunk)
	if err != nil {
		t.Fatal(err)
	}
	var rootM voilapb.Manifest
	if err := proto.Unmarshal(rootBlob, &rootM); err != nil {
		t.Fatal(err)
	}
	if len(rootM.Dirs) == 0 {
		t.Error("merged root manifest has no dirs")
	}
	inodes := collectAllInodes(&rootM, store)
	for _, p := range []string{"README", "usr", "etc", "etc/hosts", "usr/bin", "usr/bin/sh"} {
		if _, ok := inodes[p]; !ok {
			t.Errorf("merged manifest missing %q (inodes=%v)", p, inodes)
		}
	}
	wantBytesIn := uint64(len("shebang") + len("127.0.0.1 localhost\n") + len("voila"))
	if res.BytesIn != wantBytesIn {
		t.Errorf("BytesIn=%d want %d", res.BytesIn, wantBytesIn)
	}
	if _, err := store.Get(context.Background(), res.Layers[0].RootManifestChunk); err != nil {
		t.Errorf("per-layer manifest chunk fetch: %v", err)
	}
}

// ----- helpers used by manifest/layout tests -----

func findDir(m *voilapb.Manifest, inode uint64) *voilapb.Dir {
	for _, d := range m.Dirs {
		if d.Inode == inode {
			return d
		}
	}
	return nil
}

func entryValueExists(dir *voilapb.Dir, inode uint64) bool {
	for _, v := range dir.Entries {
		if v == inode {
			return true
		}
	}
	return false
}

// reconstructCounts sums dirs + files across a manifest and its external
// subtrees, fetched from store.
func reconstructCounts(m *voilapb.Manifest, store chunkstore.ChunkStore) (dirs int, files int) {
	dirs = len(m.Dirs)
	files = len(m.Files)
	for _, chunkID := range m.ExternalSubtrees {
		cid := chunkstore.ChunkID{}
		copy(cid[:], chunkID)
		blob, err := store.Get(context.Background(), cid)
		if err != nil {
			continue
		}
		var cm voilapb.Manifest
		if err := proto.Unmarshal(blob, &cm); err != nil {
			continue
		}
		d, f := reconstructCounts(&cm, store)
		dirs += d
		files += f
	}
	return
}

// collectAllInodes reconstructs full-path → inode by walking dirs and external
// subtrees. Names accumulate via dir.Entries; the root dir is path "".
func collectAllInodes(root *voilapb.Manifest, store chunkstore.ChunkStore) map[string]uint64 {
	out := map[string]uint64{}
	walkNames(root, "", store, out)
	return out
}

func walkNames(m *voilapb.Manifest, prefix string, store chunkstore.ChunkStore, out map[string]uint64) {
	for _, d := range m.Dirs {
		selfPath := prefix
		if d.Inode != 1 {
			// Best-effort: find this dir's name from a parent we've already
			// walked; if not found, use its inode as the name.
			if name, ok := findNameForInode(out, d.Inode); ok {
				selfPath = joinPath(prefix, name)
			} else {
				selfPath = joinPath(prefix, fmt.Sprintf("inode-%d", d.Inode))
			}
		}
		out[selfPath] = d.Inode
		for name, childInode := range d.Entries {
			out[joinPath(selfPath, name)] = childInode
		}
	}
	for _, chunkID := range m.ExternalSubtrees {
		cid := chunkstore.ChunkID{}
		copy(cid[:], chunkID)
		blob, err := store.Get(context.Background(), cid)
		if err != nil {
			continue
		}
		var cm voilapb.Manifest
		if err := proto.Unmarshal(blob, &cm); err != nil {
			continue
		}
		walkNames(&cm, "", store, out)
	}
}

func findNameForInode(paths map[string]uint64, inode uint64) (string, bool) {
	for p, v := range paths {
		if v == inode {
			return p, true
		}
	}
	return "", false
}

func joinPath(a, b string) string {
	if a == "" {
		return b
	}
	return a + "/" + b
}

func init() {
	_ = sort.Strings
}
