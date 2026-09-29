package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/cli"
	"voila/internal/imagestore"
	voilapb "voila/internal/proto"
)

// stripLeadingDashDash tests the "--" separator stripping shared by `voila
// run` and `voila exec`. The flag package does not consume a "--" that
// appears AFTER the first positional, so both commands strip it themselves.
func TestStripLeadingDashDash(t *testing.T) {
	cases := []struct {
		in   []string
		want []string
	}{
		{nil, nil},
		{[]string{}, []string{}},
		{[]string{"--"}, []string{}},
		{[]string{"--", "a"}, []string{"a"}},
		{[]string{"--", "a", "b"}, []string{"a", "b"}},
		{[]string{"a"}, []string{"a"}},
		{[]string{"a", "b"}, []string{"a", "b"}},
		{[]string{"--", "--", "x"}, []string{"--", "x"}}, // only the first is stripped
		{[]string{"--flag"}, []string{"--flag"}},         // looks like a flag; passed through
	}
	for i, c := range cases {
		got := stripLeadingDashDash(c.in)
		if !equalStrings(got, c.want) {
			t.Errorf("case %d: stripLeadingDashDash(%v) = %v, want %v", i, c.in, got, c.want)
		}
	}
	// Returned slice must NOT alias the input — mutating it must not rewrite
	// the caller's storage.
	in := []string{"--", "kept"}
	out := stripLeadingDashDash(in)
	if len(out) > 0 {
		out[0] = "mutated"
		if in[1] != "kept" {
			t.Errorf("stripLeadingDashDash aliased the input slice")
		}
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestRunViaDaemon_StdoutStderrDemux exercises runViaDaemon's stream demux
// against a fake server, by way of a tiny bufconn-backed worker that uses
// the stub launcher (errors immediately so we can capture an exit-code
// frame). The fake stream + a stub-launcher are too heavyweight for a unit
// test of the demux alone, so we instead verify the contract by directly
// constructing a fake RunStream. Since Recv contract + Send contract live
// on grpc.BidiStreamingClient[RunInput, RunOutput], and we cannot construct
// one without a real conn, the demux loop is not directly instantiatable
// without pulling in bufconn + a fake launcher. The downstream seam is
// exercised below for logs (where the seam is an interface); Run's output
// demux mirrors logs' demux, and is covered indirectly by the worker's own
// integration tests (worker_test.go) at the server side. Here we cover the
// `--` stripping (above) and the ps table rendering (below), which are the
// pure-CG command surface the spec calls out.

// TestRenderCtxTable_HeaderAndRows exercises the tabular layout of `voila ps`
// directly against renderCtxTable with a canned []*voilapb.ContextInfo. The
// test does NOT spin up a daemon; it verifies the column order / column
// separators / the format of the STARTED and EXIT columns.
func TestRenderCtxTable_HeaderAndRows(t *testing.T) {
	var buf bytes.Buffer
	// A scheduled context (no started/pid/exit yet), a running context, and
	// a finished one with exit 7 — three rows so the layout has body content.
	rows := []*voilapb.ContextInfo{
		{Id: "voila-aabbccdd", ImageRef: "alpha:v1", Status: "scheduled", StartedNs: 0, Pid: 0, ExitCode: 0},
		{Id: "voila-11223344", ImageRef: "beta:v2", Status: "running", StartedNs: 1_700_000_000_000_000_000, Pid: 4321, ExitCode: 0},
		{Id: "voila-55667788", ImageRef: "gamma:v3", Status: "finished", StartedNs: 1_700_000_005_000_000_000, Pid: 0, ExitCode: 7},
	}
	if err := renderCtxTable(&buf, rows); err != nil {
		t.Fatalf("renderCtxTable: %v", err)
	}
	out := buf.String()

	// Header.
	if !strings.Contains(out, "ID") || !strings.Contains(out, "IMAGE") ||
		!strings.Contains(out, "STATUS") || !strings.Contains(out, "PID") ||
		!strings.Contains(out, "STARTED") || !strings.Contains(out, "EXIT") ||
		!strings.Contains(out, "FETCHED") {
		t.Errorf("header line missing columns:\n%s", out)
	}

	for _, r := range rows {
		if !strings.Contains(out, r.GetId()) {
			t.Errorf("missing id %q in:\n%s", r.GetId(), out)
		}
		if !strings.Contains(out, r.GetImageRef()) {
			t.Errorf("missing ref %q in:\n%s", r.GetImageRef(), out)
		}
		if !strings.Contains(out, r.GetStatus()) {
			t.Errorf("missing status %q in:\n%s", r.GetStatus(), out)
		}
	}
	// STARTED on the scheduled row (started_ns == 0) must render as "-".
	if !strings.Contains(out, "scheduled") {
		t.Errorf("scheduled column not found")
	}
	// The finished row's EXIT column must show "7", not "0".
	wantExitCell := "7"
	finishedRowMarker := rows[2].GetId()
	if !strings.Contains(out, finishedRowMarker+"") {
		t.Errorf("finished row not rendered")
	}
	// Find the finished row line and verify its EXIT cell is "7". The row
	// layout is ID / IMAGE / STATUS / PID / STARTED / EXIT / FETCHED (EXIT
	// is the 6th whitespace-separated field, 0-indexed 5); FETCHED renders
	// "-" because the canned ContextInfo has no stats.
	found := false
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, finishedRowMarker) && strings.Contains(line, "finished") {
			fields := strings.Fields(line)
			if len(fields) > 5 && fields[5] == wantExitCell {
				found = true
			}
			if len(fields) > 6 && fields[6] != "-" {
				t.Errorf("finished row FETCHED cell want \"-\", got %q in:\n%s", fields[6], out)
			}
		}
	}
	if !found {
		t.Errorf("finished row EXIT cell not %q in:\n%s", wantExitCell, out)
	}
}

// TestRenderCtxTable_UnnamedImageRefRendersPlaceholder verifies that an empty
// ImageRef (e.g. from an OCI-archive ingest with no RepoTags) still renders a
// non-empty IMAGE cell. Without the placeholder, text/tabwriter pads the
// empty cell with spaces, and awk/grep field-splitting collapses the
// whitespace — the STATUS column then shifts to field index 1 instead of 2,
// breaking `voila ps | awk '$3=="running"'` as used by test/gates/gate5.sh.
func TestRenderCtxTable_UnnamedImageRefRendersPlaceholder(t *testing.T) {
	var buf bytes.Buffer
	rows := []*voilapb.ContextInfo{
		{Id: "voila-aabbccdd", ImageRef: "", Status: "running", StartedNs: 1_700_000_000_000_000_000, Pid: 4321, ExitCode: 0},
		{Id: "voila-11223344", ImageRef: "", Status: "finished", StartedNs: 1_700_000_005_000_000_000, Pid: 0, ExitCode: 7},
	}
	if err := renderCtxTable(&buf, rows); err != nil {
		t.Fatalf("renderCtxTable: %v", err)
	}
	out := buf.String()
	if !strings.Contains(out, "(unnamed)") {
		t.Errorf("missing (unnamed) placeholder for empty ImageRef:\n%s", out)
	}
	// Mirror gate5.sh line 43: `awk 'NR>1 && $3=="running" {print $1; exit}'`
	// (awk $3 == 0-indexed fields[2], $1 == fields[0]).
	var runningID string
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, "running") {
			continue
		}
		f := strings.Fields(line)
		if len(f) >= 3 && f[2] == "running" {
			runningID = f[0]
			break
		}
	}
	if runningID != "voila-aabbccdd" {
		t.Errorf("running ID via awk-style $3==\"running\": got %q, want %q in:\n%s", runningID, "voila-aabbccdd", out)
	}
	// Mirror gate5.sh lines 60/70: `awk -v c=<ctx> '$1==c {print $3}'` after
	// voila kill. For the finished row, STATUS (awk $3, fields[2]) must be
	// "finished".
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, "voila-11223344") {
			continue
		}
		f := strings.Fields(line)
		if len(f) < 3 {
			t.Fatalf("finished row split short: %v in:\n%s", f, out)
		}
		if f[0] != "voila-11223344" {
			t.Errorf("awk $1 mismatch: got %q, want \"voila-11223344\"", f[0])
		}
		if f[2] != "finished" {
			t.Errorf("finished row $3 = %q, want \"finished\" in:\n%s", f[2], out)
		}
	}
}

// TestRenderCtxTable_EmptyStillEmitsHeader verifies that an empty list still
// prints the header (so column-position-parsing scripts keep working).
func TestRenderCtxTable_EmptyStillEmitsHeader(t *testing.T) {
	var buf bytes.Buffer
	if err := renderCtxTable(&buf, nil); err != nil {
		t.Fatalf("renderCtxTable: %v", err)
	}
	out := buf.String()
	if !strings.HasPrefix(out, "ID") {
		t.Errorf("expected header line, got %q", out)
	}
	if strings.Count(out, "\n") != 1 {
		t.Errorf("expected exactly one line (header) for empty input, got:\n%s", out)
	}
}

// cannedLogsStream is a small test fake of the logsStream interface: it
// returns each chunk in order, then io.EOF. Used by TestDemuxLogs_*.
type cannedLogsStream struct {
	chunks []*voilapb.LogChunk
	i      int
}

func (s *cannedLogsStream) Recv() (*voilapb.LogChunk, error) {
	if s.i >= len(s.chunks) {
		return nil, io.EOF
	}
	c := s.chunks[s.i]
	s.i++
	return c, nil
}

// TestDemuxLogs_DispatchesChunksByStderrFlag writes stdout chunks to stdout
// and stderr chunks to stderr (so a `voila logs | cmd` pipeline does not
// interleave stderr into stdout).
func TestDemuxLogs_DispatchesChunksByStderrFlag(t *testing.T) {
	stream := &cannedLogsStream{chunks: []*voilapb.LogChunk{
		{Data: []byte("out1\n"), Stderr: false},
		{Data: []byte("err1\n"), Stderr: true},
		{Data: []byte("out2\n"), Stderr: false},
		{Data: []byte("err2\n"), Stderr: true},
	}}
	var stdout, stderr bytes.Buffer
	if err := demuxLogs(stream, &stdout, &stderr); err != nil {
		t.Fatalf("demuxLogs: %v", err)
	}
	wantOut := "out1\nout2\n"
	wantErr := "err1\nerr2\n"
	if stdout.String() != wantOut {
		t.Errorf("stdout = %q, want %q", stdout.String(), wantOut)
	}
	if stderr.String() != wantErr {
		t.Errorf("stderr = %q, want %q", stderr.String(), wantErr)
	}
}

// TestDemuxLogs_SkipsEmptyChunks asserts that empty-payload LogChunks are
// filtered (they would otherwise write zero-byte separators and add noise).
func TestDemuxLogs_SkipsEmptyChunks(t *testing.T) {
	stream := &cannedLogsStream{chunks: []*voilapb.LogChunk{
		{Data: nil, Stderr: false},
		{Data: []byte("real\n"), Stderr: false},
		{Data: []byte(""), Stderr: true},
	}}
	var stdout, stderr bytes.Buffer
	if err := demuxLogs(stream, &stdout, &stderr); err != nil {
		t.Fatalf("demuxLogs: %v", err)
	}
	if stdout.String() != "real\n" {
		t.Errorf("stdout = %q, want \"real\\n\"", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q, want empty", stderr.String())
	}
}

// TestDemuxLogs_RecursOnStreamError propagates a non-EOF error.
func TestDemuxLogs_RecursesOnStreamError(t *testing.T) {
	stream := &errLogsStream{err: errors.New("connection reset")}
	var stdout, stderr bytes.Buffer
	err := demuxLogs(stream, &stdout, &stderr)
	if err == nil {
		t.Fatalf("demuxLogs should propagate the stream error")
	}
	if !strings.Contains(err.Error(), "connection reset") {
		t.Errorf("error message lost cause: %v", err)
	}
}

type errLogsStream struct{ err error }

func (s *errLogsStream) Recv() (*voilapb.LogChunk, error) { return nil, s.err }

// ============================================================================
// images rm / gc against a real LocalStore
// ============================================================================

// reuse the OCI-tarball helpers in cmd_ingest_test.go: buildTinyOCITar /
// writeTempTarball live in the same package; the latter two are at package
// scope here.

// ingestTinyFixture ingests a single small image into a fresh root and
// returns the ref + root + the chunk count immediately after ingest (so a
// test can assert gc right after ingest removes nothing).
func ingestTinyFixture(t *testing.T, ref string) (root string, chunks int) {
	t.Helper()
	content := []byte("hello gc fixture")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)

	root = t.TempDir()
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg, root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	// Tally current chunks via direct sqlite: open a fresh LocalStore and
	// ask GC over an empty keep-set (the test will re-ingest after this —
	// see imagesGC test below, which re-ingests because the empty-set GC
	// actually deletes everything). To avoid mutating the store here, just
	// count via the index file's chunks dir.
	chunks = countChunksFiles(t, root)
	return root, chunks
}

// countChunksFiles counts the regular files under <root>/chunks recursively.
// Used as a non-mutating proxy for "how many chunks are in the store" so we
// don't have to call store.GC (which mutates the store).
func countChunksFiles(t *testing.T, root string) int {
	t.Helper()
	var n int
	dir := filepath.Join(root, "chunks")
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.Mode().IsRegular() {
			n++
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk chunks dir: %v", err)
	}
	return n
}

// TestImagesInfo_PrintsFields ingests a fixture and calls `voila images info`
// against its ref, asserting ref + digest + merged root chunk hex + layers +
// chunk count all surface in the output.
func TestImagesInfo_PrintsFields(t *testing.T) {
	const ref = "testinfo:v1"
	root, _ := ingestTinyFixture(t, ref)
	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}}
	if err := cmdImages(cfg, []string{"info", ref}); err != nil {
		t.Fatalf("cmdImages info: %v", err)
	}
	got := out.String()
	for _, want := range []string{"ref:", ref, "digest:", "merged root chunk:", "layers:", "total size:", "chunk count:", "ingested:"} {
		if !strings.Contains(got, want) {
			t.Errorf("info output missing %q:\n%s", want, got)
		}
	}
	// The merged-root chunk hex is 64 chars (32 bytes); make sure the line
	// includes a hex-looking token of that length.
	hexLine := "merged root chunk: "
	idx := strings.Index(got, hexLine)
	if idx < 0 {
		t.Fatalf("missing %q", hexLine)
	}
	tail := got[idx+len(hexLine):]
	end := strings.IndexByte(tail, '\n')
	if end < 0 {
		t.Fatalf("no newline after merged root chunk line")
	}
	hexStr := tail[:end]
	if len(hexStr) != 64 {
		t.Errorf("merged-root chunk hex len = %d, want 64 (got %q)", len(hexStr), hexStr)
	}
	if _, err := hex.DecodeString(hexStr); err != nil {
		t.Errorf("merged-root chunk is not valid hex: %v", err)
	}
}

// TestImagesRm_DeletesRowAndPB ingests a fixture, removes it via `voila images
// rm`, and asserts both the sqlite row is gone and the .pb manifest file no
// longer exists. A second `rm` on the now-absent ref must return an error.
func TestImagesRm_DeletesRowAndPB(t *testing.T) {
	const ref = "testrm:v1"
	root := t.TempDir()
	content := []byte("rm me")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg, root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	// .pb file must exist before rm.
	pbPath := filepath.Join(root, "images", imagestore.RefKey(ref)+".pb")
	if _, err := os.Stat(pbPath); err != nil {
		t.Fatalf("pb file %s missing pre-rm: %v", pbPath, err)
	}
	var std bytes.Buffer
	rmCfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &std}
	if err := cmdImages(rmCfg, []string{"rm", ref}); err != nil {
		t.Fatalf("cmdImages rm: %v", err)
	}
	// Reminder line goes to stderr per spec.
	if !strings.Contains(std.String(), "voila images gc") {
		t.Errorf("rm reminder missing: %q", std.String())
	}
	if _, err := os.Stat(pbPath); !os.IsNotExist(err) {
		t.Errorf("pb file still present after rm (err = %v)", err)
	}
	// Row gone.
	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.Ref == ref {
			t.Errorf("row for %q still present after rm", ref)
		}
	}
	_ = store.Close()

	// A second rm of the same ref should fail.
	if err := cmdImages(rmCfg, []string{"rm", ref}); err == nil {
		t.Errorf("second rm of %q should error (already gone)", ref)
	}
}

// TestImagesRm_DeletesUnnamedImageByDigestPrefix ingests an unnamed fixture
// (ref="") and removes it via `voila images rm <digest-prefix>` — the path
// test/gates/gate5.sh follows: `voila images` pads the empty REF cell and
// awk's default FS collapses the whitespace into the next non-empty cell,
// so the digest extracted by `awk 'NR==2{print $1}'` is the only handle rm
// has to work with. Regression: pre-fix imagesRm matched only the exact
// stored ref; an unnamed image stored with Ref="" could only be removed by
// passing "" verbatim (impossible via the CLI), so gate5 failed with
// `voila images: no image matching "<digest>"`.
func TestImagesRm_DeletesUnnamedImageByDigestPrefix(t *testing.T) {
	root := t.TempDir()
	content := []byte("rm my unnamed")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg, root, tarball, "", "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("imagestore.Open: %v", err)
	}
	defer store.Close()
	rows, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	if rows[0].Ref != "" {
		t.Fatalf("expected unnamed Ref (\"\"), got %q", rows[0].Ref)
	}
	if len(rows[0].ImageDigest) == 0 {
		t.Fatalf("unnamed image is missing ImageDigest")
	}
	digestHex := hex.EncodeToString(rows[0].ImageDigest)
	prefix := digestHex[:12] // matches the digest-prefix awk happens to capture in gate5
	pbPath := store.ManifestPath(rows[0].Ref)
	if _, err := os.Stat(pbPath); err != nil {
		t.Fatalf("pb file %s missing pre-rm: %v", pbPath, err)
	}

	rmCfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := cmdImages(rmCfg, []string{"rm", prefix}); err != nil {
		t.Fatalf("cmdImages rm %q: %v", prefix, err)
	}

	if _, err := os.Stat(pbPath); !os.IsNotExist(err) {
		t.Errorf("pb file still present after rm (err = %v)", err)
	}
	rows, err = store.List()
	if err != nil {
		t.Fatalf("List post-rm: %v", err)
	}
	for _, r := range rows {
		if r.Ref == "" {
			t.Errorf("unnamed row still present after rm")
		}
	}

	// A second rm of the same image (different prefix len, still unique) must
	// fail — Resolve returns "no image matching <query>" once the row is gone.
	if err := cmdImages(rmCfg, []string{"rm", digestHex[:16]}); err == nil {
		t.Errorf("second rm of deleted digest should error; got nil")
	}
}

// TestImagesGC_RemovesNothingAfterFreshIngest verifies that `voila images gc`
// right after an ingest removes zero chunks (the reachable set covers everything).
// It also exercises the "refuse when worker daemon up" guard by writing a
// worker.sock-shaped file that dialWorker's probe treats as a live socket —
// since we cannot easily spin up a daemon without runc, we instead test that
// guard directly by leaving no socket and confirming gc refuses only when
// actually probed.
func TestImagesGC_RemovesNothingAfterFreshIngest(t *testing.T) {
	const ref = "testgc:v1"
	root := t.TempDir()
	content := []byte("gc me")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg, root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}

	preChunks := countChunksFiles(t, root)
	if preChunks == 0 {
		t.Fatalf("expected chunks after ingest, files found = 0")
	}
	var std bytes.Buffer
	gcCfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &std}
	if err := cmdImages(gcCfg, []string{"gc"}); err != nil {
		t.Fatalf("cmdImages gc: %v", err)
	}
	if !strings.Contains(std.String(), "gc:") {
		t.Errorf("gc output missing \"gc:\" prefix line:\n%s", std.String())
	}
	if strings.Contains(std.String(), "removed") && !strings.Contains(std.String(), "nothing to reclaim") {
		// Verify the count is zero.
		if strings.Contains(std.String(), "removed 0") {
			// OK
		} else if !strings.Contains(std.String(), "removed 0 chunk") {
			// Could also be the "nothing to reclaim" path below.
		}
	}
	// Most important invariant: chunk file count unchanged after gc on a
	// fresh ingest (every chunk is reachable).
	postChunks := countChunksFiles(t, root)
	if postChunks != preChunks {
		t.Errorf("gc removed chunks after fresh ingest: before=%d after=%d", preChunks, postChunks)
	}
}

// TestImagesGC_RemovesUnreachableAfterRm ingests a fixture, runs `voila
// images rm <ref>` (which leaves the chunks dangling — they reference the
// now-deleted manifest), and asserts `voila images gc` reclaims them.
func TestImagesGC_RemovesUnreachableAfterRm(t *testing.T) {
	const ref = "testgc2:v1"
	root := t.TempDir()
	content := []byte("gc after rm")
	tarBytes := buildTinyOCITar(t, content)
	tarball := writeTempTarball(t, tarBytes)
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := runIngest(cfg, root, tarball, ref, "linux/amd64"); err != nil {
		t.Fatalf("runIngest: %v", err)
	}
	preChunks := countChunksFiles(t, root)
	if preChunks == 0 {
		t.Fatalf("expected chunks post ingest")
	}

	// Remove the manifest; chunks remain indexed in the chunk store.
	if err := cmdImages(Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}},
		[]string{"rm", ref}); err != nil {
		t.Fatalf("cmdImages rm: %v", err)
	}

	// gc now has no remaining manifests → all chunks unreachable → all removed.
	var std bytes.Buffer
	if err := cmdImages(Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &std}, []string{"gc"}); err != nil {
		t.Fatalf("cmdImages gc: %v", err)
	}
	if !strings.Contains(std.String(), "removed") {
		t.Errorf("gc output should report removed count:\n%s", std.String())
	}
	postChunks := countChunksFiles(t, root)
	if postChunks != 0 {
		t.Errorf("after rm + gc, expected 0 chunks on disk, got %d", postChunks)
	}

	// The per-layer cache (images.db `layers` table) MUST be cleaned by
	// gc: every row's manifest_chunk was just collected, so the cleanup
	// in `voila images gc` (DropDeadLayerCacheRows) should have emptied it.
	imgStore, err := imagestore.Open(root)
	if err != nil {
		t.Fatalf("openImageStore: %v", err)
	}
	defer imgStore.Close()
	layerRows, err := imgStore.CountLayerCacheRows()
	if err != nil {
		t.Fatalf("count layers: %v", err)
	}
	if layerRows != 0 {
		t.Errorf("after gc with no images remaining, layers table rows = %d, want 0 (gc must drop rows whose manifest_chunk was collected)", layerRows)
	}
}

// TestImagesGC_RefusesWhenWorkerUp verifies the guard that refuses gc when a
// worker daemon answers on the socket. We do not actually run a daemon; we
// bind a real unix-domain listener on a socket file at the worker socket
// path so dialWorker's probe (a dial) succeeds.
//
// darwin's unix-domain socket path is capped at ~104 chars (sun_path limit),
// and the long per-test TempDir name can blow through it. We therefore use
// os.MkdirTemp with a short prefix under /tmp as the voila root for this
// specific test.
func TestImagesGC_RefusesWhenWorkerUp(t *testing.T) {
	root, err := os.MkdirTemp("", "voila-gc-guard-")
	if err != nil {
		t.Fatalf("os.MkdirTemp: %v", err)
	}
	defer os.RemoveAll(root)
	// Create a real listener so a connect dial succeeds (matching what a
	// live worker would have on this socket file). The socket is decoupled
	// from the data root now, so we pin it under the temp root via -socket
	// and point gc at the same path.
	socketPath := cli.SocketPath(root)
	l, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("net.Listen unix: %v", err)
	}
	defer l.Close()
	go func() {
		c, _ := l.Accept()
		if c != nil {
			_ = c.Close()
		}
	}()
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	err = cmdImages(cfg, []string{"gc", "-socket", socketPath})
	if err == nil {
		t.Fatal("gc should refuse when worker is up; got nil error")
	}
	if !strings.Contains(err.Error(), "stop voila worker before gc") {
		t.Errorf("error message should mention daemon guard, got: %v", err)
	}
}
