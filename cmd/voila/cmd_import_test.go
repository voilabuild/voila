package main

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/imagestore"
	"voila/internal/ingest"
	"voila/internal/ocireg"
	voilapb "voila/internal/proto"
	"voila/internal/registry"

	"google.golang.org/protobuf/proto"
)

// fakeImportClient is a tiny ingest.RegistryClient used by the cmd import
// smoke test (kept separate from the ingest package's fakeRegistryClient so
// the cmd package stays self-contained, mirroring cmd_ingest_test.go which
// also inlines its own OCI-tar builder).
type fakeImportClient struct {
	manifest     *ocireg.Manifest
	config       []byte
	layers       [][]byte
	configDigest string
	layerDigests []string
}

func newFakeImportClient(content []byte) *fakeImportClient {
	var layerBuf bytes.Buffer
	lw := tar.NewWriter(&layerBuf)
	if err := lw.WriteHeader(&tar.Header{
		Name: "hello.txt", Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(content)),
	}); err != nil {
		panic(err)
	}
	lw.Write(content)
	lw.Close()
	layer := layerBuf.Bytes()

	configJSON := []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	configDigest := "sha256:" + sha256HexB(configJSON)
	layerDigest := "sha256:" + sha256HexB(layer)
	manifestJSON := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"%s","size":%d}]}`,
		configDigest, len(configJSON), layerDigest, len(layer)))

	return &fakeImportClient{
		manifest: &ocireg.Manifest{
			RawManifest: manifestJSON,
			Digest:      "sha256:" + sha256HexB(manifestJSON),
			Config: ocireg.Descriptor{
				Digest:    configDigest,
				MediaType: "application/vnd.oci.image.config.v1+json",
				Size:      int64(len(configJSON)),
			},
			Layers: []ocireg.Descriptor{{
				Digest:    layerDigest,
				MediaType: "application/vnd.oci.image.layer.v1.tar",
				Size:      int64(len(layer)),
			}},
		},
		config:       configJSON,
		layers:       [][]byte{layer},
		configDigest: configDigest,
		layerDigests: []string{layerDigest},
	}
}

func sha256HexB(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (f *fakeImportClient) Resolve(ctx context.Context, ref ocireg.Ref, platform string) (*ocireg.Manifest, error) {
	return f.manifest, nil
}

func (f *fakeImportClient) Blob(ctx context.Context, ref ocireg.Ref, digest string) (io.ReadCloser, int64, error) {
	switch digest {
	case f.configDigest:
		return io.NopCloser(bytes.NewReader(f.config)), int64(len(f.config)), nil
	case f.layerDigests[0]:
		return io.NopCloser(bytes.NewReader(f.layers[0])), int64(len(f.layers[0])), nil
	}
	return nil, 0, fmt.Errorf("unknown blob %s", digest)
}

// TestRunImport_Smoke runs the factored import command body against a fake
// registry client (wired via the importClient seam) and verifies the same
// persistence + summary contract as TestRunIngest_Smoke: an ImageManifest pb
// under <root>/images/, one sqlite row, and a summary that names the source.
func TestRunImport_Smoke(t *testing.T) {
	content := []byte("imported via voila import")
	prev := importClient
	importClient = newFakeImportClient(content)
	defer func() { importClient = prev }()

	root := t.TempDir()
	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &out}

	refStr := "registry.example.com/test/img:latest"
	publishRef, err := runImport(cfg, root, refStr, "", "linux/amd64", "", "", false, "")
	if err != nil {
		t.Fatalf("runImport: %v", err)
	}
	if publishRef != "" {
		t.Errorf("publishRef = %q, want \"\" (non-interactive, no -push)", publishRef)
	}

	summary := out.String()
	for _, want := range []string{"imported", "ingest summary", refStr, "bytes in", "chunks stored"} {
		if !strings.Contains(summary, want) {
			t.Errorf("summary missing %q:\n%s", want, summary)
		}
	}

	// One ImageManifest pb under images/, with the canonical ref.
	entries, err := os.ReadDir(filepath.Join(root, "images"))
	if err != nil {
		t.Fatalf("read images dir: %v", err)
	}
	var pbFile string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".pb") {
			pbFile = e.Name()
			break
		}
	}
	if pbFile == "" {
		t.Fatalf("no .pb manifest written; entries=%v", entries)
	}
	pbBytes, err := os.ReadFile(filepath.Join(root, "images", pbFile))
	if err != nil {
		t.Fatal(err)
	}
	var im voilapb.ImageManifest
	if err := proto.Unmarshal(pbBytes, &im); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if im.GetImageRef() != refStr {
		t.Errorf("image_ref = %q, want %q", im.GetImageRef(), refStr)
	}
	if len(im.GetProvenanceLayers()) != 1 {
		t.Errorf("provenance layers = %d, want 1", len(im.GetProvenanceLayers()))
	}

	// One sqlite row with the canonical ref.
	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := store.List()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("db rows = %d, want 1", len(rows))
	}
	if rows[0].Ref != refStr {
		t.Errorf("db ref = %q, want %q", rows[0].Ref, refStr)
	}
	_ = store.Close()
}

// TestRunImport_RefOverride verifies -ref renames the stored image.
func TestRunImport_RefOverride(t *testing.T) {
	prev := importClient
	importClient = newFakeImportClient([]byte("renamed"))
	defer func() { importClient = prev }()

	root := t.TempDir()
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	publishRef, err := runImport(cfg, root, "registry.example.com/x:latest", "renamed:v1", "", "", "", false, "")
	if err != nil {
		t.Fatalf("runImport: %v", err)
	}
	if publishRef != "" {
		t.Errorf("publishRef = %q, want \"\"", publishRef)
	}
	store, _ := imagestore.Open(root)
	defer store.Close()
	rows, _ := store.List()
	if len(rows) != 1 || rows[0].Ref != "renamed:v1" {
		t.Errorf("db ref = %+v, want renamed:v1", rows)
	}
}

// TestCmdImport_BadRef verifies a malformed ref surfaces a clear error.
func TestCmdImport_BadRef(t *testing.T) {
	cfg := Config{Root: t.TempDir(), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := cmdImport(cfg, []string{"@notadigest"}); err == nil {
		t.Fatal("expected error for bad ref, got nil")
	}
}

// TestRunImport_ResolveRoundTrip is the end-to-end regression for the
// README quickstart break: `voila import python:3.13` stores under the
// canonical `registry-1.docker.io/library/python:3.13`, so a later lookup
// with the SAME short ref the user typed (`voila run python:3.13` resolves
// via imagestore.Resolve) must find it.
func TestRunImport_ResolveRoundTrip(t *testing.T) {
	prev := importClient
	importClient = newFakeImportClient([]byte("round trip"))
	defer func() { importClient = prev }()

	root := t.TempDir()
	cfg := Config{Root: root, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if _, err := runImport(cfg, root, "python:3.13", "", "", "", "", false, ""); err != nil {
		t.Fatalf("runImport(python:3.13): %v", err)
	}

	store, err := imagestore.Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	const wantRef = "registry-1.docker.io/library/python:3.13"
	im, rootChunk, err := imagestore.Resolve(store, "python:3.13")
	if err != nil {
		t.Fatalf("Resolve(python:3.13) after import: %v", err)
	}
	if got := im.GetImageRef(); got != wantRef {
		t.Errorf("resolved ref = %q, want %q", got, wantRef)
	}
	if len(rootChunk) != 32 {
		t.Errorf("root chunk len = %d, want 32", len(rootChunk))
	}
}

// TestPromptPublishTarget covers the interactive publish offer: decline,
// accept with the $VOILA_ORG suggestion, accept with a custom target, and
// accept-with-garbage (which must skip publishing, not fail the import).
func TestPromptPublishTarget(t *testing.T) {
	const stored = "registry-1.docker.io/library/python:3.13"
	tests := []struct {
		name       string
		in         string
		org        string
		wantTarget string
		wantOK     bool
	}{
		{name: "decline", in: "n\n", org: "myorg", wantTarget: "", wantOK: false},
		{name: "accept default suggestion", in: "y\n\n", org: "myorg", wantTarget: "registry-1.docker.io/myorg/python:3.13", wantOK: true},
		{name: "accept custom", in: "y\nteam/img:9\n", org: "", wantTarget: "registry-1.docker.io/team/img:9", wantOK: true},
		{name: "accept garbage skips", in: "y\n@bad\n", org: "myorg", wantTarget: "", wantOK: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			target, ok := promptPublishTarget(strings.NewReader(tc.in), &out, stored, tc.org)
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v (out=%q)", ok, tc.wantOK, out.String())
			}
			if target != tc.wantTarget {
				t.Errorf("target = %q, want %q (out=%q)", target, tc.wantTarget, out.String())
			}
		})
	}
}

// TestShortImageName checks the familiar short form used in the prompt
// suggestion.
func TestShortImageName(t *testing.T) {
	tests := []struct{ in, want string }{
		{"registry-1.docker.io/library/python:3.13", "python:3.13"},
		{"ghcr.io/acme/tool:v2", "acme/tool:v2"},
		{"alpine", "alpine:latest"},
	}
	for _, tc := range tests {
		if got := shortImageName(tc.in); got != tc.want {
			t.Errorf("shortImageName(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestCmdImport_PushFlagEndToEnd drives the full import → tag → push flow:
// the OCI source is faked via the importClient seam, the voila registry is a
// real Server over httptest, and -push publishes under the org ref without
// any prompt.
func TestCmdImport_PushFlagEndToEnd(t *testing.T) {
	prev := importClient
	importClient = newFakeImportClient([]byte("pushed via import -push"))
	defer func() { importClient = prev }()

	regStore := newRegistryStore(t)
	regSrv, err := registry.NewServer(regStore, filepath.Join(t.TempDir(), "images"))
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	regSrv.SetLogger(log.New(io.Discard, "", 0))
	ts := httptest.NewServer(regSrv.Handler())
	defer ts.Close()

	root := t.TempDir()
	var out bytes.Buffer
	cfg := Config{Root: root, Stdout: &out, Stderr: &bytes.Buffer{}}

	err = cmdImport(cfg, []string{
		"-push", "myorg/img:v1",
		"-registry", ts.URL,
		"registry.example.com/test/img:1",
	})
	if err != nil {
		t.Fatalf("cmdImport: %v", err)
	}

	summary := out.String()
	for _, want := range []string{
		"imported ",
		"tagged registry.example.com/test/img:1 -> myorg/img:v1",
		"pushed myorg/img:v1:",
	} {
		if !strings.Contains(summary, want) {
			t.Errorf("output missing %q:\n%s", want, summary)
		}
	}

	// The manifest must be retrievable from the registry under the org ref.
	client, err := registry.NewClient(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	im, err := client.GetImageManifest(context.Background(), "myorg/img:v1")
	if err != nil {
		t.Fatalf("GetImageManifest(myorg/img:v1): %v", err)
	}
	if im.GetImageRef() != "myorg/img:v1" {
		t.Errorf("published image_ref = %q", im.GetImageRef())
	}
}

// TestCmdImport_PushWithoutRegistry fails fast BEFORE downloading when -push
// names a target but no registry URL is configured.
func TestCmdImport_PushWithoutRegistry(t *testing.T) {
	prev := importClient
	importClient = newFakeImportClient([]byte("never fetched"))
	defer func() { importClient = prev }()

	t.Setenv("VOILA_REGISTRY", "")
	cfg := Config{Root: t.TempDir(), Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	err := cmdImport(cfg, []string{"-push", "myorg/x:1", "registry.example.com/x:1"})
	if err == nil {
		t.Fatal("expected error for -push without a registry, got nil")
	}
	if !strings.Contains(err.Error(), "no registry configured") {
		t.Errorf("error = %v, want 'no registry configured' hint", err)
	}
}

// keep imports used.
var _ = ingest.Options{}
