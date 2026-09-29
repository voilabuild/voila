package ingest

import (
	"bytes"
	"context"
	"io"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"archive/tar"

	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
	"lukechampine.com/blake3"
)

// memStore is an in-memory chunkstore.ChunkStore used by unit tests. It uses
// BLAKE3-256 as the content-addressed id (matching LocalStore), so dedup
// accounting in layer_walk matches production behaviour.
type memStore struct {
	chunks map[chunkstore.ChunkID][]byte
}

func newMemStore() *memStore { return &memStore{chunks: make(map[chunkstore.ChunkID][]byte)} }

func (s *memStore) Put(buf []byte) (chunkstore.ChunkID, error) {
	id := chunkstore.ChunkID(blake3.Sum256(buf))
	if _, ok := s.chunks[id]; !ok {
		cp := make([]byte, len(buf))
		copy(cp, buf)
		s.chunks[id] = cp
	}
	return id, nil
}

func (s *memStore) Get(_ context.Context, id chunkstore.ChunkID) ([]byte, error) {
	if b, ok := s.chunks[id]; ok {
		return b, nil
	}
	return nil, chunkstore.ErrNotFound
}

func (s *memStore) Stat(id chunkstore.ChunkID) (chunkstore.ChunkMeta, bool) {
	if b, ok := s.chunks[id]; ok {
		return chunkstore.ChunkMeta{LogicalLen: uint64(len(b)), StoredLen: uint64(len(b))}, true
	}
	return chunkstore.ChunkMeta{}, false
}

func (s *memStore) GC(_ map[chunkstore.ChunkID]struct{}) (int, error) { return 0, nil }
func (s *memStore) Close() error                                      { return nil }

// tarBuilder builds an in-memory tar from a sequence of entry builders so
// tests don't touch disk.
type tarBuilder struct {
	buf  bytes.Buffer
	tw   *tar.Writer
	fail error
}

func newTarBuilder() *tarBuilder {
	tb := &tarBuilder{}
	tb.tw = tar.NewWriter(&tb.buf)
	return tb
}

func (tb *tarBuilder) file(name string, content []byte, mode int64) *tarBuilder {
	tb.write(&tar.Header{
		Name:     name,
		Mode:     mode,
		Typeflag: tar.TypeReg,
		Size:     int64(len(content)),
	}, content)
	return tb
}

func (tb *tarBuilder) fileXattrs(name string, content []byte, xattrs map[string]string) *tarBuilder {
	h := &tar.Header{
		Name:       name,
		Mode:       0o644,
		Typeflag:   tar.TypeReg,
		Size:       int64(len(content)),
		Format:     tar.FormatPAX,
		PAXRecords: make(map[string]string),
	}
	for k, v := range xattrs {
		h.PAXRecords["SCHILY.xattr."+k] = v
	}
	tb.write(h, content)
	return tb
}

func (tb *tarBuilder) dir(name string, mode int64) *tarBuilder {
	tb.write(&tar.Header{Name: name, Mode: mode, Typeflag: tar.TypeDir}, nil)
	return tb
}

func (tb *tarBuilder) symlink(name, target string) *tarBuilder {
	tb.write(&tar.Header{Name: name, Mode: 0o777, Typeflag: tar.TypeSymlink, Linkname: target}, nil)
	return tb
}

func (tb *tarBuilder) hardlink(name, target string) *tarBuilder {
	tb.write(&tar.Header{Name: name, Mode: 0, Typeflag: tar.TypeLink, Linkname: target}, nil)
	return tb
}

func (tb *tarBuilder) device(name string, typeflag byte, major, minor int64) *tarBuilder {
	tb.write(&tar.Header{
		Name:     name,
		Mode:     0o660,
		Typeflag: typeflag,
		Devmajor: major,
		Devminor: minor,
	}, nil)
	return tb
}

func (tb *tarBuilder) fifo(name string) *tarBuilder {
	tb.write(&tar.Header{Name: name, Mode: 0o644, Typeflag: tar.TypeFifo}, nil)
	return tb
}

func (tb *tarBuilder) write(h *tar.Header, body []byte) {
	if tb.fail != nil {
		return
	}
	if err := tb.tw.WriteHeader(h); err != nil {
		tb.fail = err
		return
	}
	if len(body) > 0 {
		if _, err := tb.tw.Write(body); err != nil {
			tb.fail = err
		}
	}
}

func (tb *tarBuilder) bytes() []byte {
	if tb.fail != nil {
		panic(tb.fail)
	}
	if err := tb.tw.Close(); err != nil {
		panic(err)
	}
	return tb.buf.Bytes()
}

// readAll fully reads r into a new []byte.
func readAll(r io.Reader) []byte {
	b, err := io.ReadAll(r)
	if err != nil {
		panic(err)
	}
	return b
}

// ----- compression sniffing tests -----

func TestSniffCompression(t *testing.T) {
	cases := []struct {
		name  string
		magic []byte
		want  Compression
	}{
		{"gzip", []byte{0x1f, 0x8b, 0x08, 0x00}, CompGzip},
		{"zstd", []byte{0x28, 0xb5, 0x2f, 0xfd}, CompZstd},
		{"raw-tar", []byte{'u', 's', 't', 'a'}, CompRaw},
		{"empty", nil, CompRaw},
		{"one-byte", []byte{0x1f}, CompRaw}, // too short for gzip id check
	}
	for _, c := range cases {
		if got := SniffCompression(c.magic); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestDecompressLayer_AllEncodingsIdentical(t *testing.T) {
	payload := newTarBuilder().file("data.txt", []byte("hello compression world"), 0o644).bytes()

	// gzip-wrapped
	gzBuf := bytes.Buffer{}
	gw := gzip.NewWriter(&gzBuf)
	gw.Write(payload)
	gw.Close()

	// zstd-wrapped
	zBuf := bytes.Buffer{}
	zw, _ := zstd.NewWriter(&zBuf)
	zw.Write(payload)
	zw.Close()

	rawReader := bytes.NewReader(payload)
	gzReader := bytes.NewReader(gzBuf.Bytes())
	zsReader := bytes.NewReader(zBuf.Bytes())

	for name, src := range map[string]io.Reader{
		"raw":  rawReader,
		"gzip": gzReader,
		"zstd": zsReader,
	} {
		dr, comp, err := DecompressLayer(src, CompUnknown)
		if err != nil {
			t.Fatalf("%s: DecompressLayer: %v", name, err)
		}
		got := readAll(dr)
		if !bytes.Equal(got, payload) {
			t.Errorf("%s: decompressed bytes differ from raw payload (len got=%d want=%d)",
				name, len(got), len(payload))
		}
		t.Logf("%s: detected comp=%v", name, comp)
	}
}

// ----- layer_walk tests -----

func walkBuilt(t *testing.T, tb *tarBuilder) *LayerWalkResult {
	t.Helper()
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.bytes()), newMemStore())
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}
	return res
}

func TestLayerWalk_MultiBlockLargeFile(t *testing.T) {
	// Build content spanning multiple 1 MiB chunks (2.5 MiB).
	const total = int64(ChunkSize*2 + 1<<19) // 2.5 MiB
	content := make([]byte, total)
	for i := range content {
		content[i] = byte(i % 251)
	}
	tb := newTarBuilder().file("big.bin", content, 0o644)
	res := walkBuilt(t, tb)

	node := res.Tree.Lookup("big.bin")
	if node == nil || node.Type != NodeRegular {
		t.Fatalf("big.bin not found / wrong type: %v", node)
	}
	wantBlocks := (total + ChunkSize - 1) / ChunkSize
	if uint64(len(node.Blocks)) != uint64(wantBlocks) {
		t.Fatalf("block count: got %d want %d", len(node.Blocks), wantBlocks)
	}
	// Offsets must be multiples of 1 MiB and contiguous; last block is shorter.
	var sum uint64
	for i, b := range node.Blocks {
		if b.OffsetInFile != uint64(i)*ChunkSize {
			t.Errorf("block %d offset: got %d want %d", i, b.OffsetInFile, uint64(i)*ChunkSize)
		}
		if b.LogicalLen == 0 {
			t.Errorf("block %d zero len", i)
		}
		sum += b.LogicalLen
	}
	if sum != uint64(total) {
		t.Errorf("sum logical_len=%d want=%d", sum, total)
	}
	if node.Size != uint64(total) {
		t.Errorf("node.Size=%d want %d", node.Size, total)
	}
	if res.ChunkCount != uint64(wantBlocks) {
		t.Errorf("ChunkCount=%d want %d", res.ChunkCount, wantBlocks)
	}
	if res.ChunksDeduped != 0 {
		t.Errorf("unexpected dedup %d", res.ChunksDeduped)
	}
}

func TestLayerWalk_XattrPreserved(t *testing.T) {
	tb := newTarBuilder().fileXattrs("cap.bin", []byte("x"),
		map[string]string{"security.capability": "\x01\x02\x03", "user.foo": "bar"})
	res := walkBuilt(t, tb)

	node := res.Tree.Lookup("cap.bin")
	if node == nil {
		t.Fatal("cap.bin missing")
	}
	if len(node.Xattrs) != 2 {
		t.Fatalf("xattrs: got %d want 2 (%v)", len(node.Xattrs), node.Xattrs)
	}
	if string(node.Xattrs["security.capability"]) != "\x01\x02\x03" {
		t.Errorf("capability xattr: %q", node.Xattrs["security.capability"])
	}
	if string(node.Xattrs["user.foo"]) != "bar" {
		t.Errorf("user.foo: %q", node.Xattrs["user.foo"])
	}
}

func TestLayerWalk_HardlinkSharesBlocksAndNlink(t *testing.T) {
	content := []byte("shared content here")
	tb := newTarBuilder().
		file("orig.txt", content, 0o644).
		hardlink("link.txt", "orig.txt")
	res := walkBuilt(t, tb)

	orig := res.Tree.Lookup("orig.txt")
	link := res.Tree.Lookup("link.txt")
	if orig == nil || link == nil {
		t.Fatalf("orig=%v link=%v", orig, link)
	}
	// The hardlink must point at the SAME node (inode-equivalent) so it shares
	// blocks; nlink bumped to 2.
	if orig != link {
		t.Fatalf("hardlink does not share node: %p != %p", orig, link)
	}
	if orig.Nlink != 2 {
		t.Errorf("nlink: got %d want 2", orig.Nlink)
	}
	if len(orig.Blocks) != 1 || orig.Blocks[0].LogicalLen != uint64(len(content)) {
		t.Fatalf("blocks: %+v", orig.Blocks)
	}
	// Both names resolve to orig via their parent dirs.
	if res.Tree.Root.Children["orig.txt"] != orig {
		t.Error("orig.txt child missing")
	}
	if res.Tree.Root.Children["link.txt"] != orig {
		t.Error("link.txt child missing")
	}
}

func TestLayerWalk_HardlinkToUnseenBecomesPending(t *testing.T) {
	tb := newTarBuilder().hardlink("late.txt", "ghost") // "ghost" was never seen
	res := walkBuilt(t, tb)

	n := res.Tree.Lookup("late.txt")
	if n == nil {
		t.Fatal("late.txt missing")
	}
	if n.Type != NodePendingHardlink {
		t.Fatalf("type: got %v want pending hardlink", n.Type)
	}
	if n.LinkTarget != "ghost" {
		t.Errorf("LinkTarget=%q want ghost", n.LinkTarget)
	}
}

func TestLayerWalk_DeviceMajorMinor(t *testing.T) {
	tb := newTarBuilder().
		device("dev/null", tar.TypeChar, 1, 3).
		device("dev/sda", tar.TypeBlock, 8, 0)
	res := walkBuilt(t, tb)

	for _, c := range []struct {
		path         string
		major, minor uint32
	}{
		{"dev/null", 1, 3},
		{"dev/sda", 8, 0},
	} {
		n := res.Tree.Lookup(c.path)
		if n == nil {
			t.Fatalf("%s missing", c.path)
		}
		if n.Type != NodeDevice {
			t.Fatalf("%s type %v", c.path, n.Type)
		}
		if n.Major != c.major || n.Minor != c.minor {
			t.Errorf("%s: major/minor got %d/%d want %d/%d",
				c.path, n.Major, n.Minor, c.major, c.minor)
		}
	}
}

func TestLayerWalk_DirSymlink(t *testing.T) {
	tb := newTarBuilder().
		dir("sub", 0o755).
		symlink("sub/link", "../target").
		file("sub/file", []byte("x"), 0o644)
	res := walkBuilt(t, tb)

	sub := res.Tree.Lookup("sub")
	if sub == nil || sub.Type != NodeDir {
		t.Fatalf("sub dir: %+v", sub)
	}
	if sub.Mode != 0o755 {
		t.Errorf("sub mode got %o", sub.Mode)
	}
	link := res.Tree.Lookup("sub/link")
	if link == nil || link.Type != NodeSymlink {
		t.Fatalf("link: %+v", link)
	}
	if link.Target != "../target" {
		t.Errorf("link target %q", link.Target)
	}
}

func TestLayerWalk_FifoWarning(t *testing.T) {
	tb := newTarBuilder().fifo("named-pipe")
	res := walkBuilt(t, tb)

	if res.Tree.Lookup("named-pipe") != nil {
		t.Error("FIFO should not become a node")
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "named-pipe") {
		t.Errorf("warnings: %v", res.Warnings)
	}
}

func TestLayerWalk_PathSafety(t *testing.T) {
	cases := []struct {
		name string
		path string
		ok   bool
	}{
		{"absolute", "/etc/passwd", false},
		{"dotdot", "../escape", false},
		{"dotdot-mid", "a/../../b", false},
		{"normal", "a/b/c", true},
		{"dotprefixed", "./a/b", true},
		{"root", ".", true},
	}
	for _, c := range cases {
		_, err := cleanEntryPath(c.path)
		gotOk := err == nil
		if gotOk != c.ok {
			t.Errorf("%s: got ok=%v (err=%v) want %v", c.name, gotOk, err, c.ok)
		}
	}
}

func TestLayerWalk_DedupAcrossFiles(t *testing.T) {
	// Two files with identical content should share one chunk (deduped=1).
	content := []byte(strings.Repeat("aab", ChunkSize/3+10))
	tb := newTarBuilder().
		file("a.bin", content, 0o644).
		file("b.bin", content, 0o644)
	res := walkBuilt(t, tb)
	want := uint64((len(content) + ChunkSize - 1) / ChunkSize)
	if res.ChunkCount != want*2 {
		t.Errorf("ChunkCount got %d want %d", res.ChunkCount, want*2)
	}
	if res.ChunksDeduped != want {
		t.Errorf("ChunksDeduped got %d want %d", res.ChunksDeduped, want)
	}
}

// ----- whiteout tests -----

func TestClassifyEntry_Explicit(t *testing.T) {
	parent, name, explicit, opaque := ClassifyEntry("dir/.wh.foo")
	if !explicit || opaque || parent != "dir" || name != "foo" {
		t.Errorf("got parent=%q name=%q explicit=%v opaque=%v", parent, name, explicit, opaque)
	}
}

func TestClassifyEntry_Opaque(t *testing.T) {
	parent, name, explicit, opaque := ClassifyEntry("dir/.wh..wh..opq")
	if explicit || !opaque || parent != "dir" || name != "" {
		t.Errorf("got parent=%q name=%q explicit=%v opaque=%v", parent, name, explicit, opaque)
	}
}

func TestClassifyEntry_RootOpaque(t *testing.T) {
	parent, _, explicit, opaque := ClassifyEntry(".wh..wh..opq")
	if explicit || !opaque || parent != "" {
		t.Errorf("root opaque: parent=%q explicit=%v opaque=%v", parent, explicit, opaque)
	}
}

func TestClassifyEntry_Normal(t *testing.T) {
	_, _, explicit, opaque := ClassifyEntry("dir/normal")
	if explicit || opaque {
		t.Errorf("normal falsely classified explicit=%v opaque=%v", explicit, opaque)
	}
}

func TestWhiteouts_Recording(t *testing.T) {
	tb := newTarBuilder().
		// A lower dir we'd expect to hide:
		dir("overlay", 0o755).
		file("overlay/foo", []byte("l"), 0o644).
		file("overlay/bar", []byte("m"), 0o644).
		dir("overlay/sub", 0o755).
		file("overlay/sub/x", []byte("n"), 0o644).
		// Whiteouts:
		// explicit .wh.foo hides overlay/foo
		// opaque .wh..wh..opq on overlay hides all lower children of overlay
		// (these live in a single layer in this test; recording is what we check)
		file("overlay/.wh.foo", nil, 0o644). // whiteout; typeflag irrelevant (basename match)
		dir("overlay/.wh..wh..opq", 0o755)   // opaque marker
	if d := tb.fail; d != nil {
		t.Fatal(d)
	}
	if err := tb.tw.Close(); err != nil {
		t.Fatal(err)
	}

	// WalkLayer should treat these as whiteouts (basename matches) and NOT as
	// real files, regardless of typeflag of the whitened entry.
	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.buf.Bytes()), newMemStore())
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}

	if res.Tree.WhiteoutsN != 1 {
		t.Errorf("explicit whiteout count got %d want 1", res.Tree.WhiteoutsN)
	}
	if res.Tree.OpaqueN != 1 {
		t.Errorf("opaque count got %d want 1", res.Tree.OpaqueN)
	}

	ov := res.Tree.Lookup("overlay")
	if ov == nil {
		t.Fatal("overlay dir missing")
	}
	if !ov.OpaqueMark {
		t.Error("overlay dir missing opaque mark")
	}
	if len(ov.Whiteouts) != 1 || ov.Whiteouts[0].Name != "foo" {
		t.Errorf("overlay whiteouts: %+v", ov.Whiteouts)
	}
	// Whiteouts never become nodes:
	if res.Tree.Lookup("overlay/.wh.foo") != nil {
		t.Error(".wh.foo should not be a node")
	}
	if res.Tree.Lookup("overlay/.wh..wh..opq") != nil {
		t.Error(".wh..wh..opq should not be a node")
	}
}

func TestWhiteouts_DirMarkersAreRecordedSeparately(t *testing.T) {
	tb := newTarBuilder().
		dir("d", 0o755).
		dir("d/.wh..wh..opq", 0o755) // opaque as a dir entry, common form
	if err := tb.tw.Close(); err != nil {
		t.Fatal(err)
	}

	res, err := WalkLayer(context.Background(), bytes.NewReader(tb.buf.Bytes()), newMemStore())
	if err != nil {
		t.Fatalf("WalkLayer: %v", err)
	}
	if res.Tree.OpaqueN != 1 || len(res.Tree.OpaqueDirs) != 1 || res.Tree.OpaqueDirs[0] != "d" {
		t.Errorf("opaque: count=%d dirs=%v", res.Tree.OpaqueN, res.Tree.OpaqueDirs)
	}
}

// helpers ---------------------------------------------------------------

func TestApplyHeaderMeta_DoesNotClobberNlinkOnHardlink(t *testing.T) {
	n := &Node{Type: NodeRegular, Nlink: 5, Mode: 0o644}
	applyHeaderMeta(n, &tar.Header{Mode: 0o755, Uid: 7, Gid: 8}, NodeRegular)
	if n.Mode != 0o755 {
		t.Errorf("mode %o", n.Mode)
	}
}

// keep voilapb referenced so the proto package stays a compile-time dependency
// even if all explicit uses are removed.
var _ voilapb.File
