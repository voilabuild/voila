package ingest

import (
	"archive/tar"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"

	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

// layoutKind discriminates the outer tarball layout.
type layoutKind int

const (
	layoutUnknown layoutKind = iota
	layoutOCI
	layoutLegacy
)

// layerDesc describes one layer blob inside the outer tarball, in lower→upper
// order (Index).
type layerDesc struct {
	// path is the entry path inside the outer tarball where the layer blob
	// (compressed or plain tar) is found.
	path string
	// index is the lower→upper position of this layer.
	index int
	// hint is the compression hint derived from the OCI mediaType (legacy
	// docker-save layers are typically raw and hint=CompUnknown so the magic
	// bytes decide).
	hint Compression
	// digest is the layer blob's OCI digest in canonical "sha256:<hex>" form
	// (the manifest's layer descriptor digest). It is the trustworthy
	// pre-stream key used for the layer cache lookup. The legacy docker-save
	// layout carries no per-layer digest in its manifest.json, so digest is
	// "" there and the layer cache is skipped for that path (Lookup never
	// called, Store never called — see ingest.go's pre-pass and Part C).
	digest string
}

// parsedLayout is the result of the layout-detection/parsing passes.
type parsedLayout struct {
	kind        layoutKind
	ref         string
	imageDigest []byte // raw 32-byte SHA-256 of the selected image manifest (OCI) or config (legacy)
	configPath  string // entry path of the config JSON inside the outer tarball
	layers      []layerDesc
}

// ErrUnknownLayout indicates the outer tarball is neither OCI-layout nor a
// legacy docker-save bundle.
var ErrUnknownLayout = errors.New("ingest: tarball is neither OCI image layout nor legacy docker save")

// layerBlobPathForDigest returns the canonical OCI blob path for a digest string
// of the form "sha256:<hex>" (or bare hex).
func layerBlobPathForDigest(d string) (string, error) {
	hexStr := strings.TrimPrefix(d, "sha256:")
	if len(hexStr) != 64 {
		return "", fmt.Errorf("ingest: bad digest %q", d)
	}
	if _, err := hex.DecodeString(hexStr); err != nil {
		return "", fmt.Errorf("ingest: bad digest hex %q: %w", d, err)
	}
	return "blobs/sha256/" + hexStr, nil
}

// digestToBytes returns the raw 32 bytes encoded by a "sha256:<hex>" (or bare
// hex) digest string.
func digestToBytes(d string) ([]byte, error) {
	hexStr := strings.TrimPrefix(d, "sha256:")
	if len(hexStr) != 64 {
		return nil, fmt.Errorf("ingest: bad digest length %q", d)
	}
	b, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, fmt.Errorf("ingest: bad digest hex %q: %w", d, err)
	}
	return b, nil
}

// parseLayout performs the layout-detection + metadata-parsing passes over the
// outer tarball at tarballPath. It does not consume blob content (config and
// layer blobs are streamed later). The returned parsedLayout drives the dispatch
// pass in Ingest.
func parseLayout(tarballPath string, opts *Options) (*parsedLayout, error) {
	oc := newLayoutCollector(tarballPath)
	if err := oc.collect(); err != nil {
		return nil, err
	}

	switch {
	case oc.hasOILayout && oc.hasIndex:
		return parseOCI(oc, opts)
	case oc.hasManifestJSON:
		return parseLegacy(oc, opts)
	default:
		return nil, ErrUnknownLayout
	}
}

// layoutCollector reads the small metadata files of the outer tarball in one
// pass.
type layoutCollector struct {
	path            string
	hasOILayout     bool
	hasIndex        bool
	hasManifestJSON bool
	indexJSON       []byte
	manifestJSON    []byte
	// manifestBlobPaths records which indices among the candidate image-manifest
	// blobs were observed, so the second pass can fetch the chosen one.
	manifestBlobPathToBytes map[string][]byte // buffered small manifest blobs (image manifests are tiny)
}

func newLayoutCollector(p string) *layoutCollector {
	return &layoutCollector{
		path:                    p,
		manifestBlobPathToBytes: map[string][]byte{},
	}
}

// collect performs one pass over the outer tar: records the presence of the
// layout-detection files and buffers their (small) contents. It also buffers
// any OCI image-manifest blobs encountered (also tiny), so the selected one is
// available without a second scan. Layer blobs are NOT buffered here; they are
// streamed later. Files larger than manifestBufferMax are NOT buffered.
func (c *layoutCollector) collect() error {
	f, err := os.Open(c.path)
	if err != nil {
		return err
	}
	defer f.Close()
	tr := tar.NewReader(f)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("ingest: scan outer tar: %w", err)
		}
		name := cleanOuterPath(hdr.Name)
		switch name {
		case "oci-layout":
			c.hasOILayout = true
		case "index.json":
			c.hasIndex = true
			c.indexJSON, err = io.ReadAll(io.LimitReader(tr, manifestBufferMax))
			if err != nil {
				return err
			}
		case "manifest.json":
			c.hasManifestJSON = true
			c.manifestJSON, err = io.ReadAll(io.LimitReader(tr, manifestBufferMax))
			if err != nil {
				return err
			}
		default:
			// Buffer small blobs/sha256 entries that look like OCI image
			// manifests (JSON, first byte '{'); the chosen one is needed to
			// derive config + layer digests without a second scan. Small binary
			// blobs (e.g. tiny layers) are skipped; readOuterEntry is the
			// second-scan fallback for anything missed.
			if strings.HasPrefix(name, "blobs/sha256/") && hdr.Size > 0 && hdr.Size <= jsonBlobBufferMax {
				var first [1]byte
				n, err := io.ReadFull(tr, first[:])
				if err != nil || n == 0 {
					continue // empty or unreadable entry; skip
				}
				if first[0] != '{' {
					continue // not JSON; a small binary layer blob
				}
				rest, err := io.ReadAll(io.LimitReader(tr, jsonBlobBufferMax))
				if err != nil {
					return err
				}
				c.manifestBlobPathToBytes[name] = append(first[:], rest...)
			}
		}
	}
}

// parseOCI parses an OCI-layout tarball: select the manifest descriptor for the
// platform (or the sole manifest), read its image manifest blob, derive config
// + ordered layer descriptors.
func parseOCI(c *layoutCollector, opts *Options) (*parsedLayout, error) {
	var idx v1.Index
	if err := json.Unmarshal(c.indexJSON, &idx); err != nil {
		return nil, fmt.Errorf("ingest: parse index.json: %w", err)
	}

	descriptor, err := selectManifestDescriptor(idx.Manifests, opts)
	if err != nil {
		return nil, err
	}
	// The selected top-level descriptor may itself be an image index (a
	// manifest list) — modern `docker save` of a multi-arch image emits a
	// nested index whose entries are the per-platform image manifests.
	// Descend through any such indexes to the concrete image manifest.
	final, manifestBytes, err := resolveImageManifest(c, descriptor, opts)
	if err != nil {
		return nil, err
	}
	digestBytes, err := digestToBytes(string(final.Digest))
	if err != nil {
		return nil, err
	}

	var im v1.Manifest
	if err := json.Unmarshal(manifestBytes, &im); err != nil {
		return nil, fmt.Errorf("ingest: parse image manifest: %w", err)
	}

	configPath, err := layerBlobPathForDigest(string(im.Config.Digest))
	if err != nil {
		return nil, fmt.Errorf("ingest: config digest: %w", err)
	}

	layers := make([]layerDesc, 0, len(im.Layers))
	for i, ld := range im.Layers {
		lp, err := layerBlobPathForDigest(string(ld.Digest))
		if err != nil {
			return nil, fmt.Errorf("ingest: layer[%d] digest: %w", i, err)
		}
		layers = append(layers, layerDesc{
			path:   lp,
			index:  i,
			hint:   mediaTypeHint(ld.MediaType),
			digest: string(ld.Digest),
		})
	}

	return &parsedLayout{
		kind:        layoutOCI,
		ref:         refFromAnnotations(descriptor.Annotations, final.Annotations, idx.Annotations),
		imageDigest: digestBytes,
		configPath:  configPath,
		layers:      layers,
	}, nil
}

// resolveImageManifest descends through nested OCI image indexes (manifest
// lists) starting at top until it reaches a concrete image manifest, returning
// the final descriptor and its raw bytes. Each nested index blob is fetched from
// the outer tarball and platform-selected with selectManifestDescriptor. A
// descriptor whose mediaType is empty is classified by sniffing the blob.
func resolveImageManifest(c *layoutCollector, top v1.Descriptor, opts *Options) (v1.Descriptor, []byte, error) {
	cur := top
	for depth := 0; depth < 16; depth++ {
		blobPath, err := layerBlobPathForDigest(string(cur.Digest))
		if err != nil {
			return v1.Descriptor{}, nil, err
		}
		blob, ok := c.manifestBlobPathToBytes[blobPath]
		if !ok {
			b, err := readOuterEntry(c.path, blobPath)
			if err != nil {
				return v1.Descriptor{}, nil, fmt.Errorf("ingest: manifest blob %q: %w", blobPath, err)
			}
			blob = b
		}

		switch {
		case isImageIndexMediaType(cur.MediaType):
			var nested v1.Index
			if err := json.Unmarshal(blob, &nested); err != nil {
				return v1.Descriptor{}, nil, fmt.Errorf("ingest: parse image index: %w", err)
			}
			next, err := selectManifestDescriptor(nested.Manifests, opts)
			if err != nil {
				return v1.Descriptor{}, nil, err
			}
			cur = next
			continue
		case isImageManifestMediaType(cur.MediaType):
			return cur, blob, nil
		default:
			// Unknown/empty mediaType: sniff the blob to classify it.
			var im v1.Manifest
			if err := json.Unmarshal(blob, &im); err == nil && im.Config.Digest != "" {
				return cur, blob, nil
			}
			var nested v1.Index
			if err := json.Unmarshal(blob, &nested); err == nil && len(nested.Manifests) > 0 {
				next, err := selectManifestDescriptor(nested.Manifests, opts)
				if err != nil {
					return v1.Descriptor{}, nil, err
				}
				cur = next
				continue
			}
			return v1.Descriptor{}, nil, fmt.Errorf("ingest: manifest blob %q is neither image manifest nor index", blobPath)
		}
	}
	return v1.Descriptor{}, nil, errors.New("ingest: image index nesting too deep")
}

// isImageIndexMediaType reports whether mt names an OCI image index or the
// docker equivalent (a manifest list).
func isImageIndexMediaType(mt string) bool {
	return mt == v1.MediaTypeImageIndex ||
		mt == "application/vnd.docker.distribution.manifest.list.v2+json"
}

// isImageManifestMediaType reports whether mt names a concrete OCI image
// manifest or the docker v2 equivalent.
func isImageManifestMediaType(mt string) bool {
	return mt == v1.MediaTypeImageManifest ||
		mt == "application/vnd.docker.distribution.manifest.v2+json"
}

// refFromAnnotations extracts an image ref from OCI annotations. Docker's
// containerd-backed `docker save` stamps the full ref as
// io.containerd.image.name on the manifest descriptor; the OCI-standard
// org.opencontainers.image.ref.name (often just the tag) is the fallback.
func refFromAnnotations(sets ...map[string]string) string {
	for _, key := range []string{"io.containerd.image.name", "org.opencontainers.image.ref.name"} {
		for _, set := range sets {
			if v := set[key]; v != "" {
				return v
			}
		}
	}
	return ""
}

// selectManifestDescriptor picks the index descriptor matching opts.Platform
// (defaulting to runtime GOOS/GOARCH). When the index has a single manifest,
// it is used regardless of platform. On no match among a multi-manifest index,
// an error lists the available platforms.
func selectManifestDescriptor(descs []v1.Descriptor, opts *Options) (v1.Descriptor, error) {
	want := defaultPlatform(opts)

	// Only consider manifest descriptors (image manifests). Some indexes mix
	// in attestation/artifact manifests without platforms; ignore those for
	// platform selection unless no platform is set on any.
	var candidates []v1.Descriptor
	for _, d := range descs {
		if d.MediaType == "" ||
			d.MediaType == v1.MediaTypeImageManifest ||
			d.MediaType == v1.MediaTypeImageIndex ||
			d.MediaType == "application/vnd.docker.distribution.manifest.v2+json" ||
			d.MediaType == "application/vnd.docker.distribution.manifest.list.v2+json" {
			candidates = append(candidates, d)
		}
	}
	if len(candidates) == 0 {
		candidates = descs
	}
	if len(candidates) == 1 {
		return candidates[0], nil
	}

	var matched []v1.Descriptor
	var avail []string
	for _, d := range candidates {
		if d.Platform == nil {
			// No platform hint: include in available but cannot match a specific
			// platform selector; treat as a wildcard only when nothing else.
			avail = append(avail, "(no platform)")
			continue
		}
		p := platformString(d.Platform)
		avail = append(avail, p)
		if p == want {
			matched = append(matched, d)
		}
	}
	if len(matched) == 1 {
		return matched[0], nil
	}
	if len(matched) > 1 {
		// Multiple exact matches: pick the first (stable).
		return matched[0], nil
	}
	return v1.Descriptor{}, fmt.Errorf(
		"ingest: no image manifest for platform %q; available: %s",
		want, strings.Join(avail, ", "))
}

func defaultPlatform(opts *Options) string {
	if opts != nil && opts.Platform != "" {
		return opts.Platform
	}
	return runtime.GOOS + "/" + runtime.GOARCH
}

func platformString(p *v1.Platform) string {
	if p == nil {
		return ""
	}
	if p.Variant != "" {
		return p.OS + "/" + p.Architecture + "/" + p.Variant
	}
	return p.OS + "/" + p.Architecture
}

// mediaTypeHint derives a compression hint from an OCI layer mediaType, falling
// back to CompUnknown (sniff) for unrecognized types.
func mediaTypeHint(mt string) Compression {
	switch {
	case strings.HasSuffix(mt, "+gzip") || strings.Contains(mt, "tar.gzip"):
		return CompGzip
	case strings.HasSuffix(mt, "+zstd") || strings.Contains(mt, "tar.zstd"):
		return CompZstd
	case strings.HasSuffix(mt, "+tar") || mt == v1.MediaTypeImageLayer:
		return CompRaw
	default:
		return CompUnknown
	}
}

// parseLegacy parses a legacy `docker save` bundle. manifest.json is an array;
// the first entry whose RepoTags contains opts.Ref (or just the first entry)
// names the config filename and ordered layer files.
func parseLegacy(c *layoutCollector, opts *Options) (*parsedLayout, error) {
	var entries []struct {
		Config   string   `json:"Config"`
		RepoTags []string `json:"RepoTags"`
		Layers   []string `json:"Layers"`
	}
	if err := json.Unmarshal(c.manifestJSON, &entries); err != nil {
		return nil, fmt.Errorf("ingest: parse manifest.json: %w", err)
	}
	if len(entries) == 0 {
		return nil, errors.New("ingest: legacy manifest.json has no entries")
	}

	var sel int
	switch {
	case opts != nil && opts.Ref != "":
		found := -1
		for i, e := range entries {
			for _, t := range e.RepoTags {
				if t == opts.Ref {
					found = i
				}
			}
		}
		if found < 0 {
			return nil, fmt.Errorf("ingest: legacy manifest.json has no entry with ref %q", opts.Ref)
		}
		sel = found
	default:
		sel = 0
	}
	entry := entries[sel]

	ref := ""
	if len(entry.RepoTags) > 0 {
		ref = entry.RepoTags[0]
	}

	layers := make([]layerDesc, 0, len(entry.Layers))
	for i, lp := range entry.Layers {
		layers = append(layers, layerDesc{
			path:  cleanOuterPath(lp),
			index: i,
			hint:  CompUnknown, // docker-save layer.tar may be raw or compressed; sniff.
		})
	}

	// imageDigest: docker save names the config blob <sha256>.json; that digest
	// is the SHA-256 of the config JSON. Fall back to nil and let Ingest compute
	// it from the config bytes if the filename is not a recognizable hex.
	var imgDigest []byte
	if hexStr, ok := stripConfigExt(entry.Config); ok {
		if b, err := hex.DecodeString(hexStr); err == nil && len(b) == 32 {
			imgDigest = b
		}
	}

	return &parsedLayout{
		kind:        layoutLegacy,
		ref:         ref,
		imageDigest: imgDigest,
		configPath:  cleanOuterPath(entry.Config),
		layers:      layers,
	}, nil
}

// stripConfigExt returns the hex prefix of a docker-save config filename like
// "<64hex>.json", ok=true when it parses; ok=false otherwise.
func stripConfigExt(name string) (string, bool) {
	name = strings.TrimPrefix(name, "./")
	dot := strings.LastIndex(name, ".")
	if dot <= 0 {
		return "", false
	}
	prefix := name[:dot]
	if len(prefix) != 64 {
		return "", false
	}
	return prefix, true
}

// cleanOuterPath normalizes an outer-tar entry name (forward slashes, no "./").
func cleanOuterPath(name string) string {
	name = strings.TrimPrefix(name, "./")
	name = strings.TrimPrefix(name, "/")
	return name
}

// readOuterEntry opens the outer tar and returns the bytes of the single entry
// named needle (exact match after cleanOuterPath). Used as a fallback when a
// needed small blob (e.g. the selected image manifest) was not buffered in the
// first scan because it appeared before index.json.
func readOuterEntry(tarballPath, needle string) ([]byte, error) {
	f, err := os.Open(tarballPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	tr := tar.NewReader(f)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			return nil, fmt.Errorf("entry %q not found", needle)
		}
		if err != nil {
			return nil, err
		}
		if cleanOuterPath(hdr.Name) == needle {
			return io.ReadAll(io.LimitReader(tr, manifestBufferMax))
		}
	}
}

// manifestBufferMax is the upper bound on metadata-file buffering during the
// layout scan (index.json / manifest.json and second-scan fallback reads).
const manifestBufferMax = 4 << 20 // 4 MiB

// jsonBlobBufferMax bounds speculative buffering of blobs/sha256 entries during
// the first scan: only JSON blobs at most this size are kept (image manifests
// are a few KiB; layer blobs are skipped and streamed later).
const jsonBlobBufferMax = 1 << 20 // 1 MiB
