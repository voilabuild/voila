// Package ocireg is a minimal OCI Distribution v2 (the "Docker Registry HTTP
// API v2") client. It exists so `voila import <ref>` can pull an image
// straight from any OCI-compliant registry (Docker Hub, quay.io, ghcr.io, a
// private registry, …) and feed its blobs into the ingest pipeline — without
// a Docker daemon and without a `docker save` tarball on disk.
//
// Scope is deliberately small: anonymous + basic-auth pull only (no push),
// manifest-list/platform selection, and blob streaming. It speaks stdlib
// net/http so it adds no new module dependencies. The wire format is the
// OCI Distribution spec: GET /v2/<name>/manifests/<reference> and
// GET /v2/<name>/blobs/<digest>, with Bearer (token-exchange) or Basic auth
// negotiated from the registry's 401 WWW-Authenticate challenge.
//
// This is unrelated to internal/registry, which is voila's OWN chunk +
// ImageManifest registry (a different wire protocol). The two packages do not
// import each other.
package ocireg

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

// DefaultHost is the registry used when a ref carries no host. It is Docker
// Hub's actual endpoint; "docker.io" is the familiar alias mapped to it.
const DefaultHost = "registry-1.docker.io"

const dockerHubAlias = "docker.io"

// Client is an OCI Distribution v2 pull client. It is safe for concurrent use
// (one *http.Client with a connection pool; per-(host,repo) bearer tokens are
// guarded by a mutex). The zero value is NOT usable — use NewClient.
type Client struct {
	httpc     *http.Client
	creds     Credentials
	plainHTTP bool

	mu     sync.Mutex
	tokens map[string]string // keyed by host + "\x00" + repo
}

// Credentials are optional registry credentials. Empty Username means
// anonymous pull (the common public-image case). Password is the password or
// a personal access token; for token-based registries (e.g. GitHub Container
// Registry) put the token in Password with the username the registry expects.
type Credentials struct {
	Username string
	Password string
}

// NewClient returns a Client. Pass empty Credentials for anonymous pull.
func NewClient(creds Credentials) *Client {
	return &Client{
		httpc: &http.Client{Timeout: 5 * time.Minute},
		creds: creds,
	}
}

// WithPlainHTTP allows http:// registry URLs (insecure; for local testing or
// a trusted on-prem registry). The default is https-only.
func (c *Client) WithPlainHTTP(allow bool) *Client {
	c.plainHTTP = allow
	return c
}

// Ref is a parsed image reference: host + repository + (tag or digest).
//
// Examples:
//
//	python:3.13                → Host=registry-1.docker.io, Repo=library/python, Tag=3.13
//	docker.io/python:3.13     → Host=registry-1.docker.io, Repo=library/python, Tag=3.13
//	quay.io/coreos/etcd:v3.5   → Host=quay.io, Repo=coreos/etcd, Tag=v3.5
//	localhost:5000/app:latest → Host=localhost:5000, Repo=app, Tag=latest
//	python@sha256:abcd…       → Host=registry-1.docker.io, Repo=library/python, Digest=sha256:abcd…
type Ref struct {
	Host     string
	Repo     string
	Tag      string
	Digest   string
	IsDigest bool
}

// String renders the canonical reference (host/repo:tag or host/repo@digest).
func (r Ref) String() string {
	if r.IsDigest {
		return r.Host + "/" + r.Repo + "@" + r.Digest
	}
	return r.Host + "/" + r.Repo + ":" + r.Tag
}

// Reference returns the reference string to fetch: the digest if set, else tag.
func (r Ref) Reference() string {
	if r.IsDigest {
		return r.Digest
	}
	return r.Tag
}

// ParseRef parses a reference into host/repository/tag-or-digest. The host
// defaults to Docker Hub (registry-1.docker.io); a bare name like "python" is
// namespaced under "library/" (Docker Hub's convention for official images).
// A reference may be a tag ("latest"), a digest ("sha256:<hex>"), or omitted
// (defaults to "latest").
func ParseRef(s string) (Ref, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return Ref{}, errors.New("ocireg: empty reference")
	}

	// A digest ("name@sha256:...") always wins over a tag.
	if i := strings.IndexByte(s, '@'); i >= 0 {
		name := s[:i]
		digest := strings.TrimSpace(s[i+1:])
		if !strings.HasPrefix(digest, "sha256:") || len(digest) != len("sha256:")+64 {
			return Ref{}, fmt.Errorf("ocireg: bad digest %q", digest)
		}
		hexStr := digest[len("sha256:"):]
		for _, r := range hexStr {
			if !isHexDigit(byte(r)) {
				return Ref{}, fmt.Errorf("ocireg: bad digest %q (non-hex char %q)", digest, r)
			}
		}
		host, repo := splitName(name)
		return Ref{Host: host, Repo: repo, Digest: digest, IsDigest: true}, nil
	}

	// Isolate the host component (the part before the first "/") to decide
	// whether a ":" is a host port or a tag separator.
	var hostPart, rest string
	if i := strings.IndexByte(s, '/'); i >= 0 {
		hostPart = s[:i]
		rest = s[i+1:]
	} else {
		rest = s
	}
	hasHostPort := strings.Contains(hostPart, ":")

	var tag string
	if hasHostPort {
		// host:port/repo[:tag] — split tag from the repo portion only.
		if j := strings.IndexByte(rest, ':'); j >= 0 {
			tag = rest[j+1:]
			rest = rest[:j]
		}
		rest = hostPart + "/" + rest
		hostPart = ""
	} else if !strings.Contains(rest, ":") {
		// no tag at all
	} else {
		// host/repo:tag or repo:tag — split tag from the repo portion.
		if j := strings.IndexByte(rest, ':'); j >= 0 {
			tag = rest[j+1:]
			rest = rest[:j]
		}
	}
	if tag == "" {
		tag = "latest"
	}

	name := rest
	if hostPart != "" {
		name = hostPart + "/" + rest
	}
	host, repo := splitName(name)
	return Ref{Host: host, Repo: repo, Tag: tag}, nil
}

// Canonical parses s as an image reference and returns its canonical form —
// exactly what Ref.String() renders and therefore what ingestion stores
// (default host, Docker Hub "library/" namespace, implicit ":latest"). It is
// the shared normalization every ref lookup should apply before matching
// against stored refs. ok is false when s does not parse as a reference
// (e.g. an empty or malformed string); note a bare hex string DOES parse
// (as a repository name), so callers that also accept digest prefixes must
// try those first.
func Canonical(s string) (canon string, ok bool) {
	ref, err := ParseRef(s)
	if err != nil {
		return "", false
	}
	return ref.String(), true
}

// splitName splits "name" (possibly "host/repo", possibly "repo") into host +
// repository, applying the Docker Hub defaults. When the host is Docker Hub
// and the repository is a single component (an official image like "python"),
// it is namespaced under "library/".
func splitName(name string) (host, repo string) {
	name = strings.TrimPrefix(name, "/")
	if i := strings.IndexByte(name, '/'); i >= 0 {
		first := name[:i]
		// A first component with a "." or ":" or equal to "localhost" is a
		// registry host; otherwise it is a Docker Hub namespace (e.g.
		// "library") and we prepend the default host.
		if strings.ContainsAny(first, ".:") || first == "localhost" {
			h := normalizeHost(first)
			r := name[i+1:]
			return h, libraryIfHub(h, r)
		}
		return DefaultHost, name
	}
	return DefaultHost, "library/" + name
}

// libraryIfHub applies Docker Hub's "library/" prefix to a single-component
// repository on the Docker Hub host (so "docker.io/python" → "library/python").
// Repositories that already have a namespace (a "/") are returned unchanged.
func libraryIfHub(host, repo string) string {
	if (host == DefaultHost) && !strings.Contains(repo, "/") {
		return "library/" + repo
	}
	return repo
}

func normalizeHost(h string) string {
	if h == dockerHubAlias {
		return DefaultHost
	}
	return h
}

// isHexDigit reports whether b is an ASCII hex digit (0-9, a-f, A-F).
func isHexDigit(b byte) bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}

// Manifest is the resolved concrete image manifest: the config descriptor and
// the ordered layer descriptors (lower→upper), plus the raw manifest bytes
// and its digest. It is what the ingest pipeline needs to drive config + layer
// blob fetches.
type Manifest struct {
	Config      Descriptor
	Layers      []Descriptor
	RawManifest []byte
	Digest      string // "sha256:<hex>" of RawManifest (from the registry header)
}

// Descriptor is one blob (config or layer) in the manifest.
type Descriptor struct {
	Digest    string
	MediaType string
	Size      int64
}

// Resolve fetches ref's manifest, descending through a manifest list / OCI
// image index to pick the concrete image manifest for platform (e.g.
// "linux/amd64"). An empty platform defaults to runtime.GOOS/GOARCH. When ref
// already points at a concrete image manifest (not a list), platform is
// ignored.
func (c *Client) Resolve(ctx context.Context, ref Ref, platform string) (*Manifest, error) {
	body, mediaType, manifestDigest, err := c.getManifest(ctx, ref)
	if err != nil {
		return nil, err
	}

	if isIndexMediaType(mediaType) {
		var idx v1.Index
		if err := json.Unmarshal(body, &idx); err != nil {
			return nil, fmt.Errorf("ocireg: parse index: %w", err)
		}
		desc, err := selectDescriptor(idx.Manifests, platform)
		if err != nil {
			return nil, err
		}
		dref := ref
		dref.Digest = string(desc.Digest)
		dref.Tag = ""
		dref.IsDigest = true
		body, mediaType, manifestDigest, err = c.getManifest(ctx, dref)
		if err != nil {
			return nil, err
		}
	}

	if !isManifestMediaType(mediaType) {
		// Sniff: a concrete image manifest has a Config descriptor.
		var probe v1.Manifest
		if err := json.Unmarshal(body, &probe); err != nil || probe.Config.Digest == "" {
			return nil, fmt.Errorf("ocireg: unexpected manifest media type %q", mediaType)
		}
	}

	var im v1.Manifest
	if err := json.Unmarshal(body, &im); err != nil {
		return nil, fmt.Errorf("ocireg: parse manifest: %w", err)
	}

	out := &Manifest{
		RawManifest: body,
		Digest:      manifestDigest,
		Config: Descriptor{
			Digest:    string(im.Config.Digest),
			MediaType: string(im.Config.MediaType),
			Size:      im.Config.Size,
		},
		Layers: make([]Descriptor, len(im.Layers)),
	}
	for i, l := range im.Layers {
		out.Layers[i] = Descriptor{
			Digest:    string(l.Digest),
			MediaType: string(l.MediaType),
			Size:      l.Size,
		}
	}
	return out, nil
}

// Blob streams the blob identified by digest under ref's repository. The
// caller must Close the returned reader. size is the blob's content length
// (resp.ContentLength; -1 when unknown).
func (c *Client) Blob(ctx context.Context, ref Ref, digest string) (io.ReadCloser, int64, error) {
	u := c.blobURL(ref, digest)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	if err := c.applyAuth(ctx, req, ref, false); err != nil {
		return nil, 0, err
	}
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, 0, err
	}
	if resp.StatusCode == http.StatusUnauthorized {
		_ = resp.Body.Close()
		req2 := req.Clone(ctx)
		if err := c.applyAuth(ctx, req2, ref, true); err != nil {
			return nil, 0, err
		}
		resp2, err := c.httpc.Do(req2)
		if err != nil {
			return nil, 0, err
		}
		if resp2.StatusCode != http.StatusOK {
			_ = resp2.Body.Close()
			return nil, 0, fmt.Errorf("ocireg: GET blob %s: %s", digest, resp2.Status)
		}
		return resp2.Body, resp2.ContentLength, nil
	}
	if resp.StatusCode != http.StatusOK {
		_ = resp.Body.Close()
		return nil, 0, fmt.Errorf("ocireg: GET blob %s: %s", digest, resp.Status)
	}
	return resp.Body, resp.ContentLength, nil
}

// getManifest fetches /v2/<repo>/manifests/<reference> with an Accept header
// advertising both image manifest and image index. It retries once with
// freshly-negotiated auth when the registry returns 401.
func (c *Client) getManifest(ctx context.Context, ref Ref) (body []byte, mediaType, digest string, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.manifestURL(ref), nil)
	if err != nil {
		return nil, "", "", err
	}
	req.Header.Set("Accept", strings.Join([]string{
		v1.MediaTypeImageManifest,
		v1.MediaTypeImageIndex,
		"application/vnd.docker.distribution.manifest.v2+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
	}, ", "))

	if err := c.applyAuth(ctx, req, ref, false); err != nil {
		return nil, "", "", err
	}
	resp, err := c.httpc.Do(req)
	if err != nil {
		return nil, "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		// Invalidate any cached token and retry once with fresh auth.
		c.invalidateToken(ref)
		req2 := req.Clone(ctx)
		if err := c.applyAuth(ctx, req2, ref, true); err != nil {
			return nil, "", "", err
		}
		resp2, err := c.httpc.Do(req2)
		if err != nil {
			return nil, "", "", err
		}
		defer resp2.Body.Close()
		if resp2.StatusCode != http.StatusOK {
			return nil, "", "", fmt.Errorf("ocireg: GET manifest %s: %s", ref.Reference(), resp2.Status)
		}
		return readManifestResp(resp2)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, "", "", fmt.Errorf("ocireg: GET manifest %s: %s", ref.Reference(), resp.Status)
	}
	return readManifestResp(resp)
}

func readManifestResp(resp *http.Response) ([]byte, string, string, error) {
	body, err := io.ReadAll(io.LimitReader(resp.Body, manifestMax))
	if err != nil {
		return nil, "", "", err
	}
	// Strip any "; charset=..." parameters so the media-type classifiers
	// (which do exact matches) see a bare type like
	// "application/vnd.oci.image.manifest.v1+json" rather than the full
	// Content-Type header some registries emit.
	return body, stripMediaTypeParams(resp.Header.Get("Content-Type")), resp.Header.Get("Docker-Content-Digest"), nil
}

// stripMediaTypeParams drops any "; param=value" tail from a Content-Type
// header value, returning the bare media type. An empty input stays empty.
func stripMediaTypeParams(ct string) string {
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		return strings.TrimSpace(ct[:i])
	}
	return strings.TrimSpace(ct)
}

// manifestMax bounds a manifest/index read. Manifests are tiny (KiB); indexes
// a little larger for multi-arch images. 16 MiB is a generous ceiling.
const manifestMax = 16 << 20

func (c *Client) scheme() string {
	if c.plainHTTP {
		return "http"
	}
	return "https"
}

func (c *Client) manifestURL(ref Ref) string {
	return fmt.Sprintf("%s://%s/v2/%s/manifests/%s",
		c.scheme(), ref.Host, escapeRepoPath(ref.Repo), url.PathEscape(ref.Reference()))
}

func (c *Client) blobURL(ref Ref, digest string) string {
	return fmt.Sprintf("%s://%s/v2/%s/blobs/%s",
		c.scheme(), ref.Host, escapeRepoPath(ref.Repo), url.PathEscape(digest))
}

// escapeRepoPath percent-escapes each path segment of a repository name
// (e.g. "library/python" or "coreos/etcd") and re-joins them with "/". Escaping
// the whole string with url.PathEscape would turn the segment separator "/"
// into "%2F", which some registries/proxies do not normalize back; escaping
// segment-by-segment keeps the path structure intact.
func escapeRepoPath(repo string) string {
	parts := strings.Split(repo, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// applyAuth sets a Bearer or Basic auth header on req. When forceReauth is
// true a cached token is ignored and re-negotiated. On a registry with no auth
// (a 200 to the unauthenticated probe), applyAuth is a no-op; the registry
// will surface a 401 if it actually requires auth and the caller retries.
func (c *Client) applyAuth(ctx context.Context, req *http.Request, ref Ref, forceReauth bool) error {
	if c.creds.Username == "" && c.creds.Password == "" {
		// Anonymous: still try a cached token (e.g. Docker Hub anon bearer).
		if tok, ok := c.token(ref, forceReauth); ok {
			req.Header.Set("Authorization", "Bearer "+tok)
			return nil
		}
		// Probe once to discover whether auth is required; if the registry
		// returns a 401 we negotiate an anonymous bearer token.
		tok, err := c.anonymousToken(ctx, ref)
		if err != nil {
			return err
		}
		if tok != "" {
			c.storeToken(ref, tok)
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		return nil
	}
	// Credentials supplied: prefer a bearer token from the token endpoint
	// (the Docker Hub / GHCR model); fall back to Basic for registries that
	// advertise Basic auth directly.
	if tok, ok := c.token(ref, forceReauth); ok {
		req.Header.Set("Authorization", "Bearer "+tok)
		return nil
	}
	tok, scheme, err := c.negotiateAuth(ctx, req, ref)
	if err != nil {
		return err
	}
	switch scheme {
	case "bearer":
		if tok != "" {
			c.storeToken(ref, tok)
			req.Header.Set("Authorization", "Bearer "+tok)
		}
	case "basic":
		req.SetBasicAuth(c.creds.Username, c.creds.Password)
	}
	return nil
}

// anonymousToken does an unauthenticated probe of the manifest endpoint and,
// if the registry responds 401 with a Bearer challenge, exchanges an
// anonymous token. It returns "" (no token needed) when the registry returns
// 200 without auth.
func (c *Client) anonymousToken(ctx context.Context, ref Ref) (string, error) {
	probe, err := http.NewRequestWithContext(ctx, http.MethodGet, c.manifestURL(ref), nil)
	if err != nil {
		return "", err
	}
	probe.Header.Set("Accept", v1.MediaTypeImageManifest)
	resp, err := c.httpc.Do(probe)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode == http.StatusOK {
		return "", nil // no auth needed
	}
	if resp.StatusCode != http.StatusUnauthorized {
		return "", fmt.Errorf("ocireg: probe %s: %s", ref.Reference(), resp.Status)
	}
	chal := resp.Header.Get("WWW-Authenticate")
	if chal == "" {
		return "", nil
	}
	return c.fetchBearerToken(ctx, ref, chal)
}

// negotiateAuth is the credentialed counterpart to anonymousToken: probe,
// and on 401 parse the challenge to decide Bearer (token exchange with the
// supplied credentials) vs Basic (send credentials directly).
func (c *Client) negotiateAuth(ctx context.Context, req *http.Request, ref Ref) (token, scheme string, err error) {
	probe := req.Clone(ctx)
	probe.Header.Del("Authorization")
	resp, err := c.httpc.Do(probe)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode == http.StatusOK {
		return "", "", nil
	}
	if resp.StatusCode != http.StatusUnauthorized {
		return "", "", fmt.Errorf("ocireg: probe %s: %s", ref.Reference(), resp.Status)
	}
	chal := resp.Header.Get("WWW-Authenticate")
	if chal == "" {
		return "", "basic", nil
	}
	lower := strings.ToLower(chal)
	switch {
	case strings.HasPrefix(lower, "bearer"):
		tok, err := c.fetchBearerToken(ctx, ref, chal)
		return tok, "bearer", err
	case strings.HasPrefix(lower, "basic"):
		return "", "basic", nil
	default:
		return "", "", fmt.Errorf("ocireg: unsupported auth challenge %q", chal)
	}
}

// fetchBearerToken parses a Bearer WWW-Authenticate challenge and exchanges
// credentials (anonymous when empty) for a token at the advertised realm.
func (c *Client) fetchBearerToken(ctx context.Context, ref Ref, chal string) (string, error) {
	realm, service, scope, err := parseBearerChallenge(chal)
	if err != nil {
		return "", err
	}
	if realm == "" {
		// Docker Hub's challenge always carries a realm; an empty realm with
		// a known host is the Docker Hub fallback.
		if ref.Host == DefaultHost {
			realm = "https://auth.docker.io/token"
			service = "registry.docker.io"
		} else {
			return "", errors.New("ocireg: bearer challenge missing realm")
		}
	}
	q := url.Values{}
	if service != "" {
		q.Set("service", service)
	}
	if scope != "" {
		q.Set("scope", scope)
	} else {
		q.Set("scope", "repository:"+ref.Repo+":pull")
	}
	tokenURL := realm
	if enc := q.Encode(); enc != "" {
		tokenURL += "?" + enc
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, tokenURL, nil)
	if err != nil {
		return "", err
	}
	if c.creds.Username != "" || c.creds.Password != "" {
		req.SetBasicAuth(c.creds.Username, c.creds.Password)
	}
	resp, err := c.httpc.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("ocireg: token exchange: %s", resp.Status)
	}
	var tok struct {
		Token string `json:"token"`
		// Some registries (e.g. GitLab) use access_token instead of token.
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&tok); err != nil {
		return "", fmt.Errorf("ocireg: parse token: %w", err)
	}
	if tok.Token != "" {
		return tok.Token, nil
	}
	return tok.AccessToken, nil
}

// parseBearerChallenge extracts realm/service/scope from a challenge like:
//
//	Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/python:pull"
func parseBearerChallenge(chal string) (realm, service, scope string, err error) {
	rest := strings.TrimSpace(chal)
	rest = strings.TrimPrefix(strings.ToLower(rest), "bearer")
	rest = strings.TrimSpace(rest)
	for rest != "" {
		var kv string
		if i := strings.IndexByte(rest, ','); i >= 0 {
			kv = rest[:i]
			rest = rest[i+1:]
		} else {
			kv = rest
			rest = ""
		}
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(kv[:eq])
		val := strings.TrimSpace(kv[eq+1:])
		val = strings.Trim(val, `"`)
		switch key {
		case "realm":
			realm = val
		case "service":
			service = val
		case "scope":
			scope = val
		}
	}
	return realm, service, scope, nil
}

func (c *Client) tokenKey(ref Ref) string { return ref.Host + "\x00" + ref.Repo }

func (c *Client) token(ref Ref, forceReauth bool) (string, bool) {
	if forceReauth {
		return "", false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tokens == nil {
		return "", false
	}
	t, ok := c.tokens[c.tokenKey(ref)]
	return t, ok
}

func (c *Client) storeToken(ref Ref, tok string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tokens == nil {
		c.tokens = map[string]string{}
	}
	c.tokens[c.tokenKey(ref)] = tok
}

func (c *Client) invalidateToken(ref Ref) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.tokens != nil {
		delete(c.tokens, c.tokenKey(ref))
	}
}

// isIndexMediaType reports whether mt names an OCI image index or the docker
// manifest-list equivalent.
func isIndexMediaType(mt string) bool {
	return mt == v1.MediaTypeImageIndex ||
		mt == "application/vnd.docker.distribution.manifest.list.v2+json"
}

// isManifestMediaType reports whether mt names a concrete image manifest.
func isManifestMediaType(mt string) bool {
	return mt == v1.MediaTypeImageManifest ||
		mt == "application/vnd.docker.distribution.manifest.v2+json"
}

// selectDescriptor picks the index descriptor matching platform (defaulting
// to runtime GOOS/GOARCH). A single-entry index is used as-is. On no match
// among a multi-entry index, an error lists the available platforms.
//
// Matching is component-wise (see platformMatches): a variant-less request
// such as "linux/arm64" matches a "linux/arm64/v8" entry, so a bare
// runtime-default platform resolves on arm64 hosts where registries tag the
// arm64 manifest with the "/v8" variant.
func selectDescriptor(descs []v1.Descriptor, platform string) (v1.Descriptor, error) {
	if len(descs) == 0 {
		return v1.Descriptor{}, errors.New("ocireg: empty manifest index")
	}
	if len(descs) == 1 {
		return descs[0], nil
	}
	wantOS, wantArch, wantVariant := parsePlatform(platform)
	if wantArch == "" {
		wantOS, wantArch = runtime.GOOS, runtime.GOARCH
	}
	want := v1.Platform{OS: wantOS, Architecture: wantArch, Variant: wantVariant}

	var matched []v1.Descriptor
	var avail []string
	for _, d := range descs {
		if d.Platform == nil {
			avail = append(avail, "(no platform)")
			continue
		}
		avail = append(avail, platformString(d.Platform))
		if platformMatches(&want, d.Platform) {
			matched = append(matched, d)
		}
	}
	if len(matched) == 1 {
		return matched[0], nil
	}
	if len(matched) > 1 {
		// A variant-less request matched several entries (e.g. an index with
		// both arm64/v8 and a hypothetical arm64/v1). Prefer the arch's
		// conventional default variant; otherwise take the first match.
		if want.Variant == "" {
			if dv := defaultVariant(want.Architecture); dv != "" {
				for _, d := range matched {
					if d.Platform != nil && d.Platform.Variant == dv {
						return d, nil
					}
				}
			}
		}
		return matched[0], nil
	}
	return v1.Descriptor{}, fmt.Errorf("ocireg: no manifest for platform %q; available: %s",
		platformString(&want), strings.Join(avail, ", "))
}
