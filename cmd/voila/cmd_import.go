// cmd_import.go implements `voila import <ref>`: pull an image straight from
// an OCI Distribution v2 registry (Docker Hub, quay.io, ghcr.io, a private
// registry, …) and ingest it into the local chunk store — no Docker daemon,
// no `docker save` tarball on disk. It is the one-command replacement for the
// two-step `docker pull && docker save -o x.tar && voila ingest x.tar` dance.
//
// Under the hood it resolves the manifest (descending a manifest list to the
// concrete image manifest for the requested platform), streams the config +
// layer blobs over HTTP, and feeds them into the SAME ingest pipeline as
// `voila ingest` (chunking, merge, per-layer + root manifests, layer cache).
// The persistence tail (ImageManifest pb + sqlite row + summary) is shared
// with `voila ingest`.
//
// Publishing: `-push <target-ref>` retags the fresh ingest under an
// org-namespaced ref and publishes it to the voila registry in the same
// command. Without the flag, an interactive session (stdin is a terminal and
// a registry is configured) offers the same via a y/N prompt; non-interactive
// runs never prompt and stay local-only.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/imagestore"
	"voila/internal/ingest"
	"voila/internal/ocireg"
)

// cmdImport implements `voila import <ref> [-ref override] [-platform os/arch]
// [-root dir] [-user user] [-password pwd] [-plain-http] [-push target]
// [-registry url]`.
func cmdImport(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "import", cfg.Stderr)
	var (
		refFlag      string
		platformFlag string
		rootFlag     string
		userFlag     string
		passwordFlag string
		plainHTTP    bool
		pushFlag     string
		registryFlag string
	)
	fs.StringVar(&refFlag, "ref", "", "override stored image ref (default: the pulled ref)")
	fs.StringVar(&platformFlag, "platform", "", "select platform os/arch for multi-arch images (default: runtime os/arch)")
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&userFlag, "user", "", "registry username for private registries (default: anonymous; $VOILA_REGISTRY_USER)")
	fs.StringVar(&passwordFlag, "password", "", "registry password / token (insecure on the CLI; prefer $VOILA_REGISTRY_PASSWORD)")
	fs.BoolVar(&plainHTTP, "plain-http", false, "allow http:// (insecure) registry URLs — for local testing")
	fs.StringVar(&pushFlag, "push", "", "retag to this org-namespaced ref and push it after ingest (e.g. myorg/python:3.13)")
	fs.StringVar(&registryFlag, "registry", "", "voila registry URL to push to (default: $VOILA_REGISTRY; only used with -push / prompt)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila import <ref> [-ref override] [-platform os/arch] [-root dir] [-user user] [-password pwd] [-plain-http] [-push target]")
	}
	refStr := fs.Arg(0)
	root := cli.ResolveRoot(rootFlag, cfg.Root)

	// Validate -push and resolve the target registry BEFORE the (potentially
	// long) download so a typo or missing config fails fast.
	var pushURL string
	if pushFlag != "" {
		if _, err := ocireg.ParseRef(pushFlag); err != nil {
			return fmt.Errorf("import: -push %q: %w", pushFlag, err)
		}
		pushURL = resolveRegistry(registryFlag)
		if pushURL == "" {
			return errors.New("no registry configured for -push: run `voila login` or set -registry / $VOILA_REGISTRY")
		}
	}

	user := userFlag
	if user == "" {
		user = os.Getenv("VOILA_REGISTRY_USER")
	}
	password := passwordFlag
	if password == "" {
		password = os.Getenv("VOILA_REGISTRY_PASSWORD")
	}

	publishRef, err := runImport(cfg, root, refStr, refFlag, platformFlag, user, password, plainHTTP, pushFlag)
	if err != nil {
		return err
	}
	if publishRef == "" {
		return nil
	}

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}
	if pushURL == "" {
		// Prompted path: the target registry was never validated up front.
		pushURL = resolveRegistry(registryFlag)
		if pushURL == "" {
			return errors.New("no registry configured: run `voila login` or set -registry / $VOILA_REGISTRY")
		}
	}
	if err := handoffRegistryCreds(cfg, rootFlag, ""); err != nil {
		return fmt.Errorf("registry handoff: %w", err)
	}
	return runPush(out, errOut, root, publishRef, pushURL, defaultPushConcurrency)
}

// runImport is the factored body of the import subcommand; tests call it
// directly with a temporary root and (optionally) a fake registry wired in
// via the importClient hook. It returns the ref that should be pushed (""
// when the import stays local): the -push flag value when given, else the
// prompt's outcome in an interactive session with a configured registry,
// else "".
func runImport(cfg Config, root, refStr, refOverride, platform, user, password string, plainHTTP bool, pushTarget string) (string, error) {
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}

	ref, err := ocireg.ParseRef(refStr)
	if err != nil {
		return "", fmt.Errorf("import: %w", err)
	}

	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fmt.Errorf("mkdir root: %w", err)
	}

	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		return "", fmt.Errorf("open chunk store: %w", err)
	}
	defer store.Close()

	imgStore, err := imagestore.Open(root)
	if err != nil {
		return "", fmt.Errorf("open image store: %w", err)
	}
	defer imgStore.Close()

	client := importClient
	if client == nil {
		client = ocireg.NewClient(ocireg.Credentials{Username: user, Password: password}).WithPlainHTTP(plainHTTP)
	}

	ctx := context.Background()
	opts := ingest.Options{
		Platform:   platform,
		Ref:        refOverride,
		LayerCache: imgStore,
	}
	res, err := ingest.IngestRegistry(ctx, client, ref, store, opts)
	if err != nil {
		return "", fmt.Errorf("import: %w", err)
	}

	im := buildImageManifest(res)
	if err := imgStore.WriteManifestPB(res.Ref, im); err != nil {
		return "", fmt.Errorf("write image manifest: %w", err)
	}

	now := time.Now().UnixNano()
	rec := imagestore.Record{
		Ref:                res.Ref,
		ImageDigest:        res.ImageDigest,
		MergedRootManifest: res.MergedRootManifestChunk[:],
		TotalSize:          int64(res.BytesIn),
		ChunkCount:         int64(res.ChunkCount),
		IngestedNS:         now,
		LastUsedNS:         now,
	}
	if err := imgStore.Upsert(rec); err != nil {
		return "", err
	}

	onDisk, err := dirSize(root)
	if err != nil {
		onDisk = 0
	}
	fmt.Fprintf(out, "imported %s from %s\n", refOrUnnamed(res.Ref), ref.Host)
	printIngestSummary(out, res, onDisk)

	// Decide the publish target: explicit flag first; then an interactive
	// offer (only with a terminal stdin AND a configured registry so scripts
	// and offline users never see it). The tag happens here while imgStore
	// is open; the caller performs the actual push once the stores are closed.
	target := ""
	switch {
	case pushTarget != "":
		target = pushTarget
	case isInteractive(cfg.Stdin) && resolveRegistry("") != "":
		t, ok := promptPublishTarget(cfg.Stdin, out, res.Ref, os.Getenv("VOILA_ORG"))
		if ok {
			target = t
		}
	}
	if target != "" && target != res.Ref {
		tagIm := buildImageManifest(res)
		if err := writeTag(imgStore, tagIm, target); err != nil {
			return "", fmt.Errorf("tag for push: %w", err)
		}
		fmt.Fprintf(out, "tagged %s -> %s\n", res.Ref, target)
	}
	if target == "" {
		return "", nil
	}
	return target, nil
}

// importClient is the test seam for runImport: when non-nil, runImport uses it
// instead of constructing a real *ocireg.Client. Tests set it to a fake
// RegistryClient backed by an in-memory image; production leaves it nil.
var importClient ingest.RegistryClient

// isInteractive reports whether r looks like a human terminal (an *os.File
// backed by a character device). Anything else — pipes, strings.Readers in
// tests, closed stdio — counts as non-interactive, which keeps prompts from
// blocking scripts and CI.
func isInteractive(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// promptPublishTarget offers to publish the freshly ingested image under an
// org-namespaced ref and reads the answer from in. defaultOrg ($VOILA_ORG)
// pre-fills the org part of the suggested target. ok=false means the user
// declined or entered something unusable (the import itself still succeeded).
//
// The suggestion reuses the stored ref's short name so `python:3.13` ingested
// as registry-1.docker.io/library/python:3.13 suggests myorg/python:3.13.
func promptPublishTarget(in io.Reader, out io.Writer, storedRef, defaultOrg string) (target string, ok bool) {
	suggestion := shortImageName(storedRef)
	if defaultOrg != "" {
		suggestion = defaultOrg + "/" + suggestion
	}
	// One buffered reader for the whole exchange: a fresh bufio per read
	// would swallow any input past the first line.
	br := bufio.NewReader(in)

	fmt.Fprintf(out, "publish %s to your registry? [y/N] ", storedRef)
	switch strings.ToLower(strings.TrimSpace(readLine(br))) {
	case "y", "yes":
	default:
		fmt.Fprintln(out, "skipped publish")
		return "", false
	}

	def := suggestion
	if def == "" {
		def = storedRef
	}
	fmt.Fprintf(out, "target ref [%s]: ", def)
	line := strings.TrimSpace(readLine(br))
	if line == "" {
		line = def
	}
	ref, err := ocireg.ParseRef(line)
	if err != nil {
		fmt.Fprintf(out, "invalid ref %q (%v); skipping publish\n", line, err)
		return "", false
	}
	return ref.String(), true
}

// readLine reads one line from br (trailing newline stripped).
func readLine(br *bufio.Reader) string {
	s, _ := br.ReadString('\n')
	return strings.TrimRight(s, "\r\n")
}

// shortImageName renders a stored ref as its familiar short form: host and
// the Docker Hub library/ namespace dropped, tag (or digest) kept —
// registry-1.docker.io/library/python:3.13 -> python:3.13.
func shortImageName(s string) string {
	ref, err := ocireg.ParseRef(s)
	if err != nil {
		return s
	}
	repo := strings.TrimPrefix(ref.Repo, "library/")
	if ref.IsDigest {
		return repo + "@" + ref.Digest
	}
	return repo + ":" + ref.Tag
}
