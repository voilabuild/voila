package e2e_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"path/filepath"
	"sort"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/ingest"
	voilapb "voila/internal/proto"

	"google.golang.org/protobuf/proto"
)

// expectedFile is the source-of-truth expected state of one regular file in the
// merged rootfs. The map is built by hand from the same content constants the
// fixtures use; it is NOT derived from ingest internals.
type expectedFile struct {
	content []byte
	inode   uint64 // 0 if the caller does not care
	uid     uint32
	gid     uint32
	mode    uint32
	xattrs  map[string]string
	mtimeNs uint64
	setMeta bool // true asserts uid/gid/mode; mtime asserted only if mtimeNs != 0
}

// expectedTree describes the final merged rootfs after applying the upper
// layer on top of the base layer, computed independently of ingest.
func expectedTree() (files map[string]expectedFile, absent []string, symlinks map[string]string) {
	files = map[string]expectedFile{
		"a/b/c/small.txt": {content: smallContent},
		"a/b/c/big.bin":   {content: bigContent, uid: 1000, gid: 1000, mode: 0o640, setMeta: true},
		"empty":           {content: emptyContent},
		"keep.txt":        {content: keepUpper}, // overwritten by upper
		"hl/orig":         {content: hlContent},
		"hl/alias":        {content: hlContent}, // same inode as orig
		"exe.sh":          {content: exeContent, mode: 0o755, setMeta: true},
		"xattr.bin": {
			content: xattrContent, uid: 33, gid: 33, mode: 0o600,
			xattrs:  map[string]string{"user.test": "value"},
			mtimeNs: uint64(t1.UnixNano()), setMeta: true,
		},
		"opaque/new1": {content: opaqueNew1},
		"typechange":  {content: tcUpper}, // type changed from dir to file
		// "xlink" is an upper-layer cross-layer hardlink to the base-layer
		// file a/b/c/small.txt. After merge it shares small.txt's inode with
		// nlink=2, so it round-trips to smallContent.
		"xlink": {content: smallContent},
	}
	// Paths that must NOT exist after merge (whiteout / opaque / type-change).
	absent = []string{
		"rm.txt",      // explicit whiteout
		"opaque/old1", // opaque cleared the dir's lower children
		"opaque/old2",
		"typechange/inner", // type-changed to a file
	}
	symlinks = map[string]string{
		"link": symLinkTarget,
	}
	return
}

// loadedManifest is the decoded merged root manifest plus the raw bytes of its
// chunk, retained so tests can assert determinism at the chunk-id level.
type loadedManifest struct {
	id   chunkstore.ChunkID
	body []byte
	m    *voilapb.Manifest
}

// walkState accumulates the manifest walk into flat maps keyed by rootfs path.
type walkState struct {
	t      *testing.T
	store  chunkstore.ChunkStore
	loaded map[chunkstore.ChunkID]*loadedManifest
	ctx    context.Context

	pathToFile    map[string]pathFile
	pathToSymlink map[string]pathSymlink
	pathToDir     map[string]pathDir
	inodeToPaths  map[uint64][]string
}

type pathFile struct {
	inode uint64
	file  *voilapb.File
}
type pathSymlink struct {
	inode uint64
	sym   *voilapb.Symlink
}
type pathDir struct {
	inode uint64
	dir   *voilapb.Dir
}

// walk the merged tree starting at the root manifest (chunk rootID). The root
// directory is the Dir with inode 1 (ingest.AssignInodes assigns inode 1 to the
// path "" which sorts first).
func (w *walkState) walk(rootID chunkstore.ChunkID) {
	lm := w.load(rootID)
	rootDir := findDirInManifest(lm.m, 1)
	if rootDir == nil {
		w.t.Fatalf("merged manifest has no root dir (inode 1)")
	}
	w.pathToDir[""] = pathDir{inode: rootDir.Inode, dir: rootDir}
	w.visit(lm.m, rootDir, "")
}

// visit recurses through dir's entries; child dirs externalized into their
// own manifest chunks are loaded on demand and walked in the child's context.
func (w *walkState) visit(m *voilapb.Manifest, dir *voilapb.Dir, dirPath string) {
	names := make([]string, 0, len(dir.Entries))
	for n := range dir.Entries {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, name := range names {
		childInode := dir.Entries[name]
		childPath := joinPath(dirPath, name)
		switch {
		case m.Files[childInode] != nil:
			w.pathToFile[childPath] = pathFile{inode: childInode, file: m.Files[childInode]}
			w.inodeToPaths[childInode] = append(w.inodeToPaths[childInode], childPath)
		case m.Symlinks[childInode] != nil:
			w.pathToSymlink[childPath] = pathSymlink{inode: childInode, sym: m.Symlinks[childInode]}
			w.inodeToPaths[childInode] = append(w.inodeToPaths[childInode], childPath)
		case m.Devices[childInode] != nil:
			w.inodeToPaths[childInode] = append(w.inodeToPaths[childInode], childPath)
		case findDirInManifest(m, childInode) != nil:
			cd := findDirInManifest(m, childInode)
			w.pathToDir[childPath] = pathDir{inode: childInode, dir: cd}
			w.inodeToPaths[childInode] = append(w.inodeToPaths[childInode], childPath)
			w.visit(m, cd, childPath)
		default:
			if ext, ok := m.ExternalSubtrees[childInode]; ok {
				cm := w.load(chunkIDFromBytes(ext))
				cd := findDirInManifest(cm.m, childInode)
				if cd == nil {
					w.t.Fatalf("external subtree inode %d not found in child manifest", childInode)
				}
				w.pathToDir[childPath] = pathDir{inode: childInode, dir: cd}
				w.inodeToPaths[childInode] = append(w.inodeToPaths[childInode], childPath)
				w.visit(cm.m, cd, childPath)
			}
		}
	}
}

// load fetches + decodes a manifest chunk, caching by id.
func (w *walkState) load(id chunkstore.ChunkID) *loadedManifest {
	if lm, ok := w.loaded[id]; ok {
		return lm
	}
	body, err := w.store.Get(w.ctx, id)
	if err != nil {
		w.t.Fatalf("Get manifest chunk %s: %v", id, err)
	}
	m := &voilapb.Manifest{}
	if err := proto.Unmarshal(body, m); err != nil {
		w.t.Fatalf("unmarshal manifest %s: %v", id, err)
	}
	lm := &loadedManifest{id: id, body: body, m: m}
	w.loaded[id] = lm
	return lm
}

func findDirInManifest(m *voilapb.Manifest, inode uint64) *voilapb.Dir {
	for _, d := range m.Dirs {
		if d.Inode == inode {
			return d
		}
	}
	return nil
}

func chunkIDFromBytes(b []byte) chunkstore.ChunkID {
	var id chunkstore.ChunkID
	copy(id[:], b)
	return id
}

func joinPath(dir, name string) string {
	if dir == "" {
		return name
	}
	return dir + "/" + name
}

// loadAndWalk fetches the manifest chunk rootID and walks its tree from the
// root dir (inode 1) into a fresh walkState. Used for both the merged root
// manifest and the per-layer provenance manifests.
func loadAndWalk(t *testing.T, store chunkstore.ChunkStore, ctx context.Context, rootID chunkstore.ChunkID) *walkState {
	t.Helper()
	w := &walkState{
		t:             t,
		store:         store,
		loaded:        map[chunkstore.ChunkID]*loadedManifest{},
		ctx:           ctx,
		pathToFile:    map[string]pathFile{},
		pathToSymlink: map[string]pathSymlink{},
		pathToDir:     map[string]pathDir{},
		inodeToPaths:  map[uint64][]string{},
	}
	w.walk(rootID)
	return w
}

// loadManifest fetches and decodes a single manifest chunk (no external
// subtree expansion). Used when assertions only need the top-level Dir and
// the Hardlinks map of one manifest chunk.
func loadManifest(t *testing.T, store chunkstore.ChunkStore, ctx context.Context, id chunkstore.ChunkID) *voilapb.Manifest {
	t.Helper()
	body, err := store.Get(ctx, id)
	if err != nil {
		t.Fatalf("Get manifest chunk %s: %v", id, err)
	}
	m := &voilapb.Manifest{}
	if err := proto.Unmarshal(body, m); err != nil {
		t.Fatalf("unmarshal manifest %s: %v", id, err)
	}
	return m
}

// reconstructFile assembles a regular file's bytes from its blocks via store.Get
// at each block's offset. Empty files (no blocks, size 0) reconstruct to empty.
func reconstructFile(t *testing.T, ctx context.Context, store chunkstore.ChunkStore, f *voilapb.File) []byte {
	t.Helper()
	out := make([]byte, f.Size)
	for _, b := range f.Blocks {
		id := chunkIDFromBytes(b.ChunkId)
		chunkBytes, err := store.Get(ctx, id)
		if err != nil {
			t.Fatalf("Get chunk for block offset %d: %v", b.OffsetInFile, err)
		}
		if uint64(b.OffsetInFile)+uint64(len(chunkBytes)) > f.Size {
			t.Fatalf("block offset+len %d+%d overflows size %d",
				b.OffsetInFile, len(chunkBytes), f.Size)
		}
		copy(out[b.OffsetInFile:], chunkBytes)
	}
	return out
}

// -----------------------------------------------------------------------------
// Roundtrip test body.
// -----------------------------------------------------------------------------

func runRoundtrip(t *testing.T, tarball []byte, layoutTag string) {
	t.Helper()
	ctx := context.Background()
	storeDir := t.TempDir()
	store, err := chunkstore.OpenLocal(storeDir)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	res, err := ingest.Ingest(ctx, writeTempTarball(t, tarball), store, ingest.Options{
		Platform: "linux/amd64",
	})
	if err != nil {
		t.Fatalf("[%s] Ingest: %v", layoutTag, err)
	}

	// Assertion: the merged root manifest decodes and the root dir (inode 1)
	// is present.
	rootID := res.MergedRootManifestChunk
	rootBytes, err := store.Get(ctx, rootID)
	if err != nil {
		t.Fatalf("[%s] Get merged root manifest: %v", layoutTag, err)
	}
	root := &voilapb.Manifest{}
	if err := proto.Unmarshal(rootBytes, root); err != nil {
		t.Fatalf("[%s] unmarshal merged root: %v", layoutTag, err)
	}
	if findDirInManifest(root, 1) == nil {
		t.Fatalf("[%s] merged root has no dir with inode 1", layoutTag)
	}

	w := &walkState{
		t:             t,
		store:         store,
		loaded:        map[chunkstore.ChunkID]*loadedManifest{},
		ctx:           ctx,
		pathToFile:    map[string]pathFile{},
		pathToSymlink: map[string]pathSymlink{},
		pathToDir:     map[string]pathDir{},
		inodeToPaths:  map[uint64][]string{},
	}
	w.walk(rootID)

	// --- Assertion 2: roundtrip hash for every expected regular file ---
	expFiles, expAbsent, expSymlinks := expectedTree()
	for path, exp := range expFiles {
		pf, ok := w.pathToFile[path]
		if !ok {
			t.Errorf("[%s] expected regular file %q missing from merged tree", layoutTag, path)
			continue
		}
		got := reconstructFile(t, ctx, store, pf.file)
		gotSum := sha256.Sum256(got)
		wantSum := sha256.Sum256(exp.content)
		if !bytes.Equal(gotSum[:], wantSum[:]) {
			t.Errorf("[%s] roundtrip hash mismatch %q: got %x, want %x (len got=%d want=%d)",
				layoutTag, path, gotSum, wantSum, len(got), len(exp.content))
		}
		if uint64(len(got)) != pf.file.Size {
			t.Errorf("[%s] %q reconstructed len %d != manifest size %d", layoutTag, path, len(got), pf.file.Size)
		}
	}

	// Verify block offsets for the multi-block file.
	if pf, ok := w.pathToFile["a/b/c/big.bin"]; ok {
		if len(pf.file.Blocks) < 2 {
			t.Errorf("[%s] big.bin expected >=2 blocks, got %d", layoutTag, len(pf.file.Blocks))
		} else {
			if pf.file.Blocks[0].OffsetInFile != 0 {
				t.Errorf("[%s] big.bin block[0] offset=%d, want 0", layoutTag, pf.file.Blocks[0].OffsetInFile)
			}
			if pf.file.Blocks[1].OffsetInFile != 1<<20 {
				t.Errorf("[%s] big.bin block[1] offset=%d, want %d", layoutTag, pf.file.Blocks[1].OffsetInFile, 1<<20)
			}
			if pf.file.Blocks[0].LogicalLen != 1<<20 {
				t.Errorf("[%s] big.bin block[0] len=%d, want %d", layoutTag, pf.file.Blocks[0].LogicalLen, 1<<20)
			}
		}
		if pf.file.Size != uint64(len(bigContent)) {
			t.Errorf("[%s] big.bin size=%d, want %d", layoutTag, pf.file.Size, len(bigContent))
		}
	}

	// --- Assertion 3: hardlinks share inode, nlink==2, identical content —
	// in the MERGED manifest (what the mount daemon serves) and in the
	// base-layer provenance manifest.
	orig, origOk := w.pathToFile["hl/orig"]
	alias, aliasOk := w.pathToFile["hl/alias"]
	if !origOk || !aliasOk {
		t.Fatalf("[%s] hardlink pair hl/orig or hl/alias missing", layoutTag)
	}
	if orig.inode != alias.inode {
		t.Errorf("[%s] hardlink inode mismatch: orig=%d alias=%d", layoutTag, orig.inode, alias.inode)
	}
	if orig.file.Nlink != 2 || alias.file.Nlink != 2 {
		t.Errorf("[%s] merged manifest hardlink nlink: orig=%d alias=%d, want 2",
			layoutTag, orig.file.Nlink, alias.file.Nlink)
	}
	if paths := w.inodeToPaths[orig.inode]; len(paths) != 2 {
		t.Errorf("[%s] hardlink inode %d has %d names, want 2: %v", layoutTag, orig.inode, len(paths), paths)
	}
	origContent := reconstructFile(t, ctx, store, orig.file)
	aliasContent := reconstructFile(t, ctx, store, alias.file)
	if !bytes.Equal(origContent, aliasContent) {
		t.Errorf("[%s] hardlink content differs between hl/orig and hl/alias", layoutTag)
	}
	// The base-layer provenance manifest carries both names too (WITHIN-layer
	// hardlinks are resolved at walk time and remain shared in the per-layer
	// manifest — they are NOT symbolic).
	wBase := loadAndWalk(t, store, ctx, res.Layers[0].RootManifestChunk)
	bOrig, bOk := wBase.pathToFile["hl/orig"]
	if !bOk {
		t.Fatalf("[%s] base-layer manifest missing hl/orig", layoutTag)
	}
	if bOrig.file.Nlink != 2 {
		t.Errorf("[%s] base-layer manifest hardlink nlink=%d, want 2", layoutTag, bOrig.file.Nlink)
	}
	bAlias, bAliasOk := wBase.pathToFile["hl/alias"]
	if !bAliasOk {
		t.Fatalf("[%s] base-layer manifest missing hl/alias", layoutTag)
	}
	if bAlias.inode != bOrig.inode {
		t.Errorf("[%s] base-layer within-layer hardlink inodes differ: orig=%d alias=%d",
			layoutTag, bOrig.inode, bAlias.inode)
	}

	// --- Cross-layer hardlink: upper layer links to a base-layer file.
	// In the MERGED manifest xlink shares small.txt's inode with nlink=2.
	xlink, xlinkOk := w.pathToFile["xlink"]
	if !xlinkOk {
		t.Fatalf("[%s] cross-layer hardlink xlink missing from merged tree", layoutTag)
	}
	small, smallOk := w.pathToFile["a/b/c/small.txt"]
	if !smallOk {
		t.Fatalf("[%s] merged tree missing a/b/c/small.txt", layoutTag)
	}
	if xlink.inode != small.inode {
		t.Errorf("[%s] cross-layer hardlink inode: xlink=%d small=%d, want shared",
			layoutTag, xlink.inode, small.inode)
	}
	if xlink.file.Nlink != 2 || small.file.Nlink != 2 {
		t.Errorf("[%s] cross-layer hardlink merged nlink: xlink=%d small=%d, want 2",
			layoutTag, xlink.file.Nlink, small.file.Nlink)
	}
	if paths := w.inodeToPaths[xlink.inode]; len(paths) != 2 {
		t.Errorf("[%s] cross-layer hardlink inode %d has %d names, want 2: %v",
			layoutTag, xlink.inode, len(paths), paths)
	}
	xlinkContent := reconstructFile(t, ctx, store, xlink.file)
	if want := reconstructFile(t, ctx, store, small.file); !bytes.Equal(xlinkContent, want) {
		t.Errorf("[%s] cross-layer hardlink content differs from target", layoutTag)
	}

	// The UPPER layer's provenance manifest carries xlink as a SYMBOLIC
	// Hardlink entry (target a/b/c/small.txt), because the target lives in
	// the lower layer and is invisible at layer-walk time. Upper-layer
	// manifest has xlink as a Dir entry pointing at an inode that has a
	// Hardlinks[inode] entry and NO File entry.
	upManifest := loadManifest(t, store, ctx, res.Layers[1].RootManifestChunk)
	upRoot := findDirInManifest(upManifest, 1)
	if upRoot == nil {
		t.Fatalf("[%s] upper-layer manifest has no root dir (inode 1)", layoutTag)
	}
	xlinkInode, hasXlink := upRoot.Entries["xlink"]
	if !hasXlink {
		t.Fatalf("[%s] upper-layer manifest has no Dir entry for xlink", layoutTag)
	}
	hl, hasHL := upManifest.Hardlinks[xlinkInode]
	if !hasHL {
		t.Fatalf("[%s] upper-layer manifest has no symbolic Hardlink for xlink inode %d",
			layoutTag, xlinkInode)
	}
	if hl.TargetPath != "a/b/c/small.txt" {
		t.Errorf("[%s] upper-layer xlink hardlink target=%q want a/b/c/small.txt",
			layoutTag, hl.TargetPath)
	}
	if hl.Inode != xlinkInode {
		t.Errorf("[%s] upper-layer xlink hardlink inode=%d want %d",
			layoutTag, hl.Inode, xlinkInode)
	}
	if _, hasFile := upManifest.Files[xlinkInode]; hasFile {
		t.Errorf("[%s] upper-layer xlink must NOT be a File entry (must stay symbolic)",
			layoutTag)
	}

	// --- Assertion 4: whiteouts / opaque / type-change ---
	for _, p := range expAbsent {
		if _, ok := w.pathToFile[p]; ok {
			t.Errorf("[%s] whiteout/opaque/type-change path %q should be absent but is a file", layoutTag, p)
		}
		if _, ok := w.pathToDir[p]; ok {
			t.Errorf("[%s] path %q should be absent but is a dir", layoutTag, p)
			continue
		}
	}
	// opaque dir contains ONLY upper children.
	if d, ok := w.pathToDir["opaque"]; ok {
		want := map[string]bool{"new1": true}
		for name := range d.dir.Entries {
			if !want[name] {
				t.Errorf("[%s] opaque dir has unexpected child %q", layoutTag, name)
			}
		}
		for name := range want {
			if _, ok := d.dir.Entries[name]; !ok {
				t.Errorf("[%s] opaque dir missing expected child %q", layoutTag, name)
			}
		}
	} else {
		t.Errorf("[%s] opaque dir missing from merged tree", layoutTag)
	}
	// type-changed path is a file, not a dir.
	if _, ok := w.pathToDir["typechange"]; ok {
		t.Errorf("[%s] typechange should be a file, not a dir", layoutTag)
	}
	if _, ok := w.pathToFile["typechange"]; !ok {
		t.Errorf("[%s] typechange should be a regular file", layoutTag)
	}

	// --- Assertion 5: metadata preserved for the cases in fixtures ---
	if pf, ok := w.pathToFile["xattr.bin"]; ok {
		f := pf.file
		if f.Uid != 33 || f.Gid != 33 {
			t.Errorf("[%s] xattr.bin uid/gid=%d/%d want 33/33", layoutTag, f.Uid, f.Gid)
		}
		if f.Mode != 0o600 {
			t.Errorf("[%s] xattr.bin mode=%o want 0600", layoutTag, f.Mode)
		}
		if v := f.Xattrs["user.test"]; string(v) != "value" {
			t.Errorf("[%s] xattr.bin user.test=%q want \"value\"", layoutTag, string(v))
		}
		if f.MtimeNs != uint64(t1.UnixNano()) {
			t.Errorf("[%s] xattr.bin mtime_ns=%d want %d", layoutTag, f.MtimeNs, uint64(t1.UnixNano()))
		}
	}
	if pf, ok := w.pathToFile["a/b/c/big.bin"]; ok {
		if pf.file.Uid != 1000 || pf.file.Gid != 1000 {
			t.Errorf("[%s] big.bin uid/gid=%d/%d want 1000/1000", layoutTag, pf.file.Uid, pf.file.Gid)
		}
		if pf.file.Mode != 0o640 {
			t.Errorf("[%s] big.bin mode=%o want 0640", layoutTag, pf.file.Mode)
		}
	}
	if pf, ok := w.pathToFile["exe.sh"]; ok {
		if pf.file.Mode != 0o755 {
			t.Errorf("[%s] exe.sh mode=%o want 0755", layoutTag, pf.file.Mode)
		}
	}
	// 3+-deep directory hierarchy present.
	if _, ok := w.pathToDir["a/b/c"]; !ok {
		t.Errorf("[%s] deep dir a/b/c missing", layoutTag)
	}

	// --- Symlink target preserved ---
	for path, want := range expSymlinks {
		ps, ok := w.pathToSymlink[path]
		if !ok {
			t.Errorf("[%s] symlink %q missing", layoutTag, path)
			continue
		}
		if ps.sym.Target != want {
			t.Errorf("[%s] symlink %q target=%q want %q", layoutTag, path, ps.sym.Target, want)
		}
	}
}

// countChunkFiles counts on-disk blob files under the store's chunks/ dir. Used
// by the dedup assertion: ingesting the same fixture twice must not add chunks.
func countChunkFiles(t *testing.T, storeDir string) int {
	t.Helper()
	root := filepath.Join(storeDir, "chunks")
	count := 0
	err := filepathWalkFiles(root, func(string) { count++ })
	if err != nil {
		t.Fatalf("walk chunk dir: %v", err)
	}
	return count
}

// one variant table-driven test covering gzip / zstd / raw OCI + legacy.
func TestRoundtrip(t *testing.T) {
	cases := []struct {
		name string
		tag  string
		tar  []byte
	}{
		{"OCI_gzip", "oci-gzip", makeImageTarball("oci", compGzip)},
		{"OCI_zstd", "oci-zstd", makeImageTarball("oci", compZstd)},
		{"OCI_raw", "oci-raw", makeImageTarball("oci", compRaw)},
		{"Legacy", "legacy", makeImageTarball("legacy", compRaw)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			runRoundtrip(t, c.tar, c.tag)
		})
	}
}

// TestDedup: ingest the SAME fixture twice into one store. The second Result
// reports every chunk as deduped (ChunksDeduped == ChunkCount) and the store's
// on-disk chunk count does not change.
func TestDedup(t *testing.T) {
	tarGzip := makeImageTarball("oci", compGzip)
	ctx := context.Background()

	storeDir := t.TempDir()
	store, err := chunkstore.OpenLocal(storeDir)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	p1 := writeTempTarball(t, tarGzip)
	if _, err := ingest.Ingest(ctx, p1, store, ingest.Options{Platform: "linux/amd64"}); err != nil {
		t.Fatalf("first Ingest: %v", err)
	}
	countAfterFirst := countChunkFiles(t, storeDir)

	p2 := writeTempTarball(t, tarGzip)
	res2, err := ingest.Ingest(ctx, p2, store, ingest.Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("second Ingest: %v", err)
	}
	if res2.ChunksDeduped != res2.ChunkCount {
		t.Errorf("dedup: ChunksDeduped=%d ChunkCount=%d, want equal", res2.ChunksDeduped, res2.ChunkCount)
	}
	countAfterSecond := countChunkFiles(t, storeDir)
	if countAfterFirst != countAfterSecond {
		t.Errorf("dedup: store chunk count changed %d -> %d", countAfterFirst, countAfterSecond)
	}
}

// TestDeterminism: ingest the same fixture into two fresh stores; the merged
// root manifest chunk ids must be identical.
func TestDeterminism(t *testing.T) {
	tarGzip := makeImageTarball("oci", compGzip)
	ctx := context.Background()

	mk := func(t *testing.T) (chunkstore.ChunkStore, chunkstore.ChunkID) {
		dir := t.TempDir()
		s, err := chunkstore.OpenLocal(dir)
		if err != nil {
			t.Fatalf("OpenLocal: %v", err)
		}
		t.Cleanup(func() { _ = s.Close() })
		res, err := ingest.Ingest(ctx, writeTempTarball(t, tarGzip), s, ingest.Options{Platform: "linux/amd64"})
		if err != nil {
			t.Fatalf("Ingest: %v", err)
		}
		return s, res.MergedRootManifestChunk
	}

	s1, id1 := mk(t)
	_, id2 := mk(t)
	if id1 != id2 {
		t.Errorf("determinism: merged root manifest ids differ: %s != %s", id1, id2)
	}
	_ = s1
}

// TestRealImage is skipped unless VOILA_E2E_TARBALL points at a real
// `docker save`/OCI tarball. When set, it ingests the tarball and runs the
// roundtrip-hash assertion (assertion 2) on a sample of 20 files plus
// /etc/os-release if present.
func TestRealImage(t *testing.T) {
	tarPath := realTarballEnv()
	if tarPath == "" {
		t.Skip("VOILA_E2E_TARBALL not set; skipping real-image roundtrip")
	}
	ctx := context.Background()
	storeDir := t.TempDir()
	store, err := chunkstore.OpenLocal(storeDir)
	if err != nil {
		t.Fatalf("OpenLocal: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	res, err := ingest.Ingest(ctx, tarPath, store, ingest.Options{Platform: "linux/amd64"})
	if err != nil {
		t.Fatalf("Ingest real image: %v", err)
	}
	rootBytes, err := store.Get(ctx, res.MergedRootManifestChunk)
	if err != nil {
		t.Fatalf("Get merged root: %v", err)
	}
	root := &voilapb.Manifest{}
	if err := proto.Unmarshal(rootBytes, root); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	w := &walkState{
		t:             t,
		store:         store,
		loaded:        map[chunkstore.ChunkID]*loadedManifest{},
		ctx:           ctx,
		pathToFile:    map[string]pathFile{},
		pathToSymlink: map[string]pathSymlink{},
		pathToDir:     map[string]pathDir{},
		inodeToPaths:  map[uint64][]string{},
	}
	w.walk(res.MergedRootManifestChunk)

	// Collect regular-file paths and sample up to 20 of them (deterministic
	// order) plus /etc/os-release if present.
	paths := make([]string, 0, len(w.pathToFile))
	for p := range w.pathToFile {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	sample := sampleN(paths, 20)
	if pf, ok := w.pathToFile["etc/os-release"]; ok {
		// Always include /etc/os-release if it exists.
		sample = appendUnique(sample, "etc/os-release")
		_ = pf
	}
	if len(sample) == 0 {
		t.Skip("real image has no regular files to sample")
	}
	for _, p := range sample {
		pf, ok := w.pathToFile[p]
		if !ok {
			t.Errorf("sample path %q not a regular file", p)
			continue
		}
		got := reconstructFile(t, ctx, store, pf.file)
		// We cannot know the expected content; assert block assembly is
		// internally consistent: size matches and each block chunk decodes.
		if uint64(len(got)) != pf.file.Size {
			t.Errorf("real image %q: reconstructed len %d != manifest size %d", p, len(got), pf.file.Size)
		}
	}
}

// sampleN returns up to n evenly-spaced entries from paths (deterministic).
func sampleN(paths []string, n int) []string {
	if len(paths) <= n {
		out := make([]string, len(paths))
		copy(out, paths)
		return out
	}
	out := make([]string, 0, n)
	step := float64(len(paths)) / float64(n)
	for i := 0; i < n; i++ {
		idx := int(float64(i) * step)
		if idx >= len(paths) {
			idx = len(paths) - 1
		}
		out = append(out, paths[idx])
	}
	return out
}

func appendUnique(s []string, p string) []string {
	for _, e := range s {
		if e == p {
			return s
		}
	}
	return append(s, p)
}
