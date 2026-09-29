package ingest

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	"voila/internal/ocireg"
)

// fakeRegistryClient is an in-memory RegistryClient for IngestRegistry tests:
// it serves the config + layer blobs of a single-arch image built in memory,
// with no HTTP server. It implements ingest.RegistryClient.
type fakeRegistryClient struct {
	t            *testing.T
	manifest     *ocireg.Manifest
	config       []byte
	layers       [][]byte
	configDigest string
	layerDigests []string
}

func newFakeRegistryClient(t *testing.T, content []byte) *fakeRegistryClient {
	t.Helper()
	var layerBuf bytes.Buffer
	lw := tar.NewWriter(&layerBuf)
	if err := lw.WriteHeader(&tar.Header{
		Name: "hello.txt", Mode: 0o644, Typeflag: tar.TypeReg, Size: int64(len(content)),
	}); err != nil {
		t.Fatal(err)
	}
	lw.Write(content)
	if err := lw.Close(); err != nil {
		t.Fatal(err)
	}
	layer := layerBuf.Bytes()

	configJSON := []byte(`{"architecture":"amd64","os":"linux","config":{},"rootfs":{"type":"layers","digests":[]},"history":[]}`)
	manifestJSON := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		sha256HexStr(configJSON), len(configJSON), sha256HexStr(layer), len(layer)))

	configDigest := "sha256:" + sha256HexStr(configJSON)
	layerDigest := "sha256:" + sha256HexStr(layer)

	return &fakeRegistryClient{
		t: t,
		manifest: &ocireg.Manifest{
			RawManifest: manifestJSON,
			Digest:      "sha256:" + sha256HexStr(manifestJSON),
			Config: ocireg.Descriptor{
				Digest:    configDigest,
				MediaType: "application/vnd.oci.image.config.v1+json",
				Size:      int64(len(configJSON)),
			},
			Layers: []ocireg.Descriptor{
				{
					Digest:    layerDigest,
					MediaType: "application/vnd.oci.image.layer.v1.tar",
					Size:      int64(len(layer)),
				},
			},
		},
		config:       configJSON,
		layers:       [][]byte{layer},
		configDigest: configDigest,
		layerDigests: []string{layerDigest},
	}
}

func sha256HexStr(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (f *fakeRegistryClient) Resolve(ctx context.Context, ref ocireg.Ref, platform string) (*ocireg.Manifest, error) {
	return f.manifest, nil
}

func (f *fakeRegistryClient) Blob(ctx context.Context, ref ocireg.Ref, digest string) (io.ReadCloser, int64, error) {
	switch digest {
	case f.configDigest:
		return io.NopCloser(bytes.NewReader(f.config)), int64(len(f.config)), nil
	case f.layerDigests[0]:
		return io.NopCloser(bytes.NewReader(f.layers[0])), int64(len(f.layers[0])), nil
	}
	return nil, 0, fmt.Errorf("fake registry: unknown blob %s", digest)
}

// TestIngestRegistry_Smoke ingests a single-layer image from the fake
// registry client and verifies the Result matches a tarball ingest of the
// same image: one layer, one chunk, the right ref, and a non-empty merged
// root manifest chunk.
func TestIngestRegistry_Smoke(t *testing.T) {
	content := []byte("hello from the registry")
	client := newFakeRegistryClient(t, content)

	dir := t.TempDir()
	store, err := chunkstore.OpenLocal(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ref := ocireg.Ref{Host: "registry.example.com", Repo: "test/img", Tag: "latest"}
	ctx := context.Background()
	res, err := IngestRegistry(ctx, client, ref, store, Options{})
	if err != nil {
		t.Fatalf("IngestRegistry: %v", err)
	}

	if res.Ref != ref.String() {
		t.Errorf("Ref = %q, want %q", res.Ref, ref.String())
	}
	if len(res.Layers) != 1 {
		t.Errorf("Layers = %d, want 1", len(res.Layers))
	}
	if res.ChunkCount != 1 {
		t.Errorf("ChunkCount = %d, want 1 (single small file)", res.ChunkCount)
	}
	if res.MergedRootManifestChunk == (chunkstore.ChunkID{}) {
		t.Error("MergedRootManifestChunk is zero")
	}
	if res.BytesIn != uint64(len(content)) {
		t.Errorf("BytesIn = %d, want %d", res.BytesIn, len(content))
	}
	if len(res.ImageDigest) != 32 {
		t.Errorf("ImageDigest len = %d, want 32", len(res.ImageDigest))
	}
}

// TestIngestRegistry_RefOverride verifies opts.Ref overrides the stored ref.
func TestIngestRegistry_RefOverride(t *testing.T) {
	client := newFakeRegistryClient(t, []byte("override me"))
	dir := t.TempDir()
	store, _ := chunkstore.OpenLocal(dir)
	defer store.Close()

	ref := ocireg.Ref{Host: "registry.example.com", Repo: "test/img", Tag: "latest"}
	res, err := IngestRegistry(context.Background(), client, ref, store, Options{Ref: "renamed:v2"})
	if err != nil {
		t.Fatalf("IngestRegistry: %v", err)
	}
	if res.Ref != "renamed:v2" {
		t.Errorf("Ref = %q, want renamed:v2", res.Ref)
	}
}

// TestIngestRegistry_MissingBlob verifies a missing layer blob surfaces a
// clear error rather than a panic.
func TestIngestRegistry_MissingBlob(t *testing.T) {
	client := newFakeRegistryClient(t, []byte("x"))
	// Corrupt the layer digest so Blob returns unknown-blob.
	client.manifest.Layers[0].Digest = "sha256:" + strings.Repeat("0", 64)

	dir := t.TempDir()
	store, _ := chunkstore.OpenLocal(dir)
	defer store.Close()

	ref := ocireg.Ref{Host: "r.example.com", Repo: "x", Tag: "latest"}
	_, err := IngestRegistry(context.Background(), client, ref, store, Options{})
	if err == nil || !strings.Contains(err.Error(), "fetch layer 0 blob") {
		t.Errorf("err = %v, want a 'fetch layer 0 blob' error", err)
	}
}
