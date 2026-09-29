package ocireg

import (
	"archive/tar"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"testing"

	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

// sha256Hex returns the sha256 hex of b.
func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// fakeRegistry is a minimal OCI Distribution v2 server backed by an in-memory
// image (config + ordered layer blobs). It optionally requires an anonymous
// bearer token (issued at /token) so the client's auth-negotiation path is
// exercised. It serves:
//
//	GET /v2/                                  → 200 (ping)
//	GET /token?service=...&scope=...          → anonymous bearer token JSON
//	GET /v2/<repo>/manifests/<ref>            → manifest (or index) bytes
//	GET /v2/<repo>/blobs/<digest>             → blob bytes
type fakeRegistry struct {
	t              *testing.T
	repo           string
	manifest       []byte // the concrete image manifest (single-arch)
	config         []byte
	layers         [][]byte // compressed-or-raw layer blobs, lower→upper
	requireAuth    bool
	token          string
	srv            *httptest.Server
	manifestDigest string
}

func newFakeRegistry(t *testing.T, content []byte) *fakeRegistry {
	t.Helper()
	// One layer: a single regular file "hello.txt" with content.
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
	configHex := sha256Hex(configJSON)
	layerHex := sha256Hex(layer)

	manifestJSON := []byte(fmt.Sprintf(
		`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}]}`,
		configHex, len(configJSON), layerHex, len(layer)))

	return &fakeRegistry{
		t:              t,
		repo:           "test/img",
		manifest:       manifestJSON,
		manifestDigest: "sha256:" + sha256Hex(manifestJSON),
		config:         configJSON,
		layers:         [][]byte{layer},
	}
}

func (f *fakeRegistry) start() {
	f.srv = httptest.NewServer(http.HandlerFunc(f.handle))
}

func (f *fakeRegistry) close() { f.srv.Close() }

func (f *fakeRegistry) base() string { return f.srv.URL }

func (f *fakeRegistry) handle(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/v2" || r.URL.Path == "/v2/":
		if f.requireAuth && r.Header.Get("Authorization") == "" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="`+f.srv.URL+`/token",service="test-registry",scope="repository:`+f.repo+`:pull"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	case r.URL.Path == "/token":
		// Anonymous token exchange: ignore credentials, issue a fixed token.
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"token":"anonymous-token"}`)
	case strings.HasPrefix(r.URL.Path, "/v2/"+f.repo+"/manifests/"):
		if f.requireAuth && r.Header.Get("Authorization") != "Bearer anonymous-token" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="`+f.srv.URL+`/token",service="test-registry",scope="repository:`+f.repo+`:pull"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		ref := strings.TrimPrefix(r.URL.Path, "/v2/"+f.repo+"/manifests/")
		if ref == "latest" || ref == f.manifestDigest {
			w.Header().Set("Content-Type", v1.MediaTypeImageManifest)
			w.Header().Set("Docker-Content-Digest", f.manifestDigest)
			w.Write(f.manifest)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	case strings.HasPrefix(r.URL.Path, "/v2/"+f.repo+"/blobs/"):
		if f.requireAuth && r.Header.Get("Authorization") != "Bearer anonymous-token" {
			w.Header().Set("WWW-Authenticate", `Bearer realm="`+f.srv.URL+`/token",service="test-registry",scope="repository:`+f.repo+`:pull"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		digest := strings.TrimPrefix(r.URL.Path, "/v2/"+f.repo+"/blobs/")
		switch digest {
		case "sha256:" + sha256Hex(f.config):
			w.Write(f.config)
		case "sha256:" + sha256Hex(f.layers[0]):
			w.Write(f.layers[0])
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

// ref returns the parsed ref for the test image (host:port/repo:latest).
func (f *fakeRegistry) ref() Ref {
	host := f.srv.Listener.Addr().String()
	return Ref{Host: host, Repo: f.repo, Tag: "latest"}
}

// clientFor builds a Client bound to the fake registry. plainHTTP is set so
// the httptest (http://) endpoint is used.
func (f *fakeRegistry) client() *Client {
	c := NewClient(Credentials{}).WithPlainHTTP(true)
	return c
}

func TestParseRef(t *testing.T) {
	cases := []struct {
		in   string
		want Ref
	}{
		{"python:3.13", Ref{Host: DefaultHost, Repo: "library/python", Tag: "3.13"}},
		{"docker.io/python:3.13", Ref{Host: DefaultHost, Repo: "library/python", Tag: "3.13"}},
		{"python", Ref{Host: DefaultHost, Repo: "library/python", Tag: "latest"}},
		{"quay.io/coreos/etcd:v3.5", Ref{Host: "quay.io", Repo: "coreos/etcd", Tag: "v3.5"}},
		{"localhost:5000/app:latest", Ref{Host: "localhost:5000", Repo: "app", Tag: "latest"}},
		{"registry.example.com:5000/org/img:tag", Ref{Host: "registry.example.com:5000", Repo: "org/img", Tag: "tag"}},
		{"python@sha256:" + strings.Repeat("a", 64), Ref{Host: DefaultHost, Repo: "library/python", Digest: "sha256:" + strings.Repeat("a", 64), IsDigest: true}},
		{"ghcr.io/owner/repo@sha256:" + strings.Repeat("b", 64), Ref{Host: "ghcr.io", Repo: "owner/repo", Digest: "sha256:" + strings.Repeat("b", 64), IsDigest: true}},
	}
	for _, c := range cases {
		got, err := ParseRef(c.in)
		if err != nil {
			t.Errorf("ParseRef(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseRef(%q) = %+v, want %+v", c.in, got, c.want)
		}
	}
}

func TestParseRef_Errors(t *testing.T) {
	for _, in := range []string{"", "python@notadigest", "python@sha256:short"} {
		if _, err := ParseRef(in); err == nil {
			t.Errorf("ParseRef(%q) = nil error, want error", in)
		}
	}
	// A digest with non-hex characters must fail fast (not slip through as a
	// later, hard-to-understand registry error).
	if _, err := ParseRef("python@sha256:" + strings.Repeat("z", 64)); err == nil {
		t.Errorf("ParseRef(non-hex digest) = nil error, want error")
	}
}

func TestStripMediaTypeParams(t *testing.T) {
	cases := map[string]string{
		"application/vnd.oci.image.manifest.v1+json":                     "application/vnd.oci.image.manifest.v1+json",
		"application/vnd.oci.image.manifest.v1+json; charset=utf-8":      "application/vnd.oci.image.manifest.v1+json",
		"  application/vnd.oci.image.index.v1+json ; charset=us-ascii  ": "application/vnd.oci.image.index.v1+json",
		"": "",
	}
	for in, want := range cases {
		if got := stripMediaTypeParams(in); got != want {
			t.Errorf("stripMediaTypeParams(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEscapeRepoPath(t *testing.T) {
	// Slashes that separate segments are preserved; per-segment special chars
	// are encoded but the separator is not turned into %2F.
	if got := escapeRepoPath("library/python"); got != "library/python" {
		t.Errorf("escapeRepoPath(library/python) = %q, want library/python", got)
	}
	if got := escapeRepoPath("coreos/etcd"); got != "coreos/etcd" {
		t.Errorf("escapeRepoPath(coreos/etcd) = %q, want coreos/etcd", got)
	}
	// A space in a segment is encoded, but the slash stays.
	const want = "my%20org/img"
	if got := escapeRepoPath("my org/img"); got != want {
		t.Errorf("escapeRepoPath(my org/img) = %q, want %q", got, want)
	}
}

func TestClient_ResolveAndBlob(t *testing.T) {
	content := []byte("hello voila world")
	f := newFakeRegistry(t, content)
	f.start()
	defer f.close()

	c := f.client()
	ctx := context.Background()
	man, err := c.Resolve(ctx, f.ref(), "linux/amd64")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if man.Config.Digest != "sha256:"+sha256Hex(f.config) {
		t.Errorf("config digest = %s, want %s", man.Config.Digest, "sha256:"+sha256Hex(f.config))
	}
	if len(man.Layers) != 1 {
		t.Fatalf("layers = %d, want 1", len(man.Layers))
	}
	if man.Layers[0].Digest != "sha256:"+sha256Hex(f.layers[0]) {
		t.Errorf("layer digest = %s", man.Layers[0].Digest)
	}
	if man.Digest != f.manifestDigest {
		t.Errorf("manifest digest = %s, want %s", man.Digest, f.manifestDigest)
	}

	// Stream the layer blob and verify bytes.
	rc, _, err := c.Blob(ctx, f.ref(), man.Layers[0].Digest)
	if err != nil {
		t.Fatalf("Blob: %v", err)
	}
	got, err := io.ReadAll(rc)
	rc.Close()
	if err != nil {
		t.Fatalf("read blob: %v", err)
	}
	if !bytes.Equal(got, f.layers[0]) {
		t.Errorf("blob bytes mismatch: got %q want %q", got, f.layers[0])
	}
}

func TestClient_AnonymousBearerAuth(t *testing.T) {
	content := []byte("auth me")
	f := newFakeRegistry(t, content)
	f.requireAuth = true
	f.start()
	defer f.close()

	c := f.client()
	ctx := context.Background()
	man, err := c.Resolve(ctx, f.ref(), "linux/amd64")
	if err != nil {
		t.Fatalf("Resolve with auth: %v", err)
	}
	if man.Config.Digest == "" {
		t.Fatal("empty config digest after auth")
	}
	// The anonymous token must be cached and reused for the blob fetch.
	rc, _, err := c.Blob(ctx, f.ref(), man.Layers[0].Digest)
	if err != nil {
		t.Fatalf("Blob with auth: %v", err)
	}
	rc.Close()
}

func TestClient_NotFound(t *testing.T) {
	f := newFakeRegistry(t, []byte("x"))
	f.start()
	defer f.close()
	c := f.client()
	_, _, err := c.Blob(context.Background(), f.ref(), "sha256:"+strings.Repeat("0", 64))
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("Blob missing = %v, want a 404 error", err)
	}
}

// TestSelectDescriptor_VariantMatching covers the multi-arch platform
// selection that selectDescriptor does (the single-arch Resolve tests above
// short-circuit on len(descs)==1). The key case: a bare "linux/arm64" request
// must match a "linux/arm64/v8" manifest entry — the regression that broke
// `voila import alpine` on arm64 hosts.
func TestSelectDescriptor_VariantMatching(t *testing.T) {
	arm64v8 := v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "arm64", Variant: "v8"}}
	armv7 := v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "arm", Variant: "v7"}}
	amd64 := v1.Descriptor{Platform: &v1.Platform{OS: "linux", Architecture: "amd64"}}
	noPlat := v1.Descriptor{Platform: nil}
	idx := []v1.Descriptor{amd64, arm64v8, armv7, noPlat}

	cases := []struct {
		name    string
		want    string
		wantErr bool
	}{
		// The regression: bare arm64 host default vs. an arm64/v8 entry.
		{"bare arm64 matches arm64/v8", "linux/arm64", false},
		// Explicit variant still works.
		{"explicit arm64/v8", "linux/arm64/v8", false},
		// amd64 (no variant) matches the variant-less amd64 entry.
		{"amd64", "linux/amd64", false},
		// arm/v7 matches arm/v7.
		{"arm/v7", "linux/arm/v7", false},
		// bare arm matches arm/v7 via the default-variant tie-break.
		{"bare arm matches arm/v7", "linux/arm", false},
		// No such platform → error listing the available ones.
		{"missing ppc64le", "linux/ppc64le", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := selectDescriptor(idx, tc.want)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("selectDescriptor(%q): want error, got %v", tc.want, got)
				}
				if !strings.Contains(err.Error(), "available:") {
					t.Errorf("error %q: want it to list available platforms", err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("selectDescriptor(%q): %v", tc.want, err)
			}
			if got.Platform == nil {
				t.Fatalf("selectDescriptor(%q): nil platform", tc.want)
			}
		})
	}

	// Pin the exact descriptor picked for the regression case so a future
	// change can't silently regress to a wrong variant.
	got, err := selectDescriptor(idx, "linux/arm64")
	if err != nil {
		t.Fatalf("arm64: %v", err)
	}
	if got.Platform.Architecture != "arm64" || got.Platform.Variant != "v8" {
		t.Errorf("arm64 pick = %s/%s, want arm64/v8", got.Platform.Architecture, got.Platform.Variant)
	}

	// Empty platform defaults to the runtime platform; on linux amd64/arm64
	// hosts it must still resolve (no error) against this index. On darwin
	// the runtime default is darwin/* which is not in this linux-only index,
	// so we accept the expected "no manifest" error there.
	if _, err := selectDescriptor(idx, ""); err != nil {
		if runtime.GOOS == "linux" {
			t.Fatalf("empty platform (runtime default): %v", err)
		}
	}

	// Single-entry index is used as-is regardless of the requested platform.
	single := []v1.Descriptor{amd64}
	got, err = selectDescriptor(single, "linux/ppc64le")
	if err != nil || got.Platform.Architecture != "amd64" {
		t.Errorf("single-entry index: got %v err=%v, want amd64 as-is", got, err)
	}
}
