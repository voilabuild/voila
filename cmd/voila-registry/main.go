// Package main is the voila-registry entry point: the voila HTTP chunk +
// ImageManifest registry server (Phase 1 of plan §4.3), backed by the SAME
// LocalStore machinery as every other voila binary plus a flat
// <root>/images/<sha256(ref) hex>.pb tree for ImageManifest blobs.
//
// This is the third binary of the three-binary split (plan §12 / task 16): the
// serve half of the old `voila registry` subcommand moves here (the
// client-side helpers resolveRegistry and the ManifestPuller adapter stay
// with cmd/voila's package, since push/pull/auto-pull wire them in). The
// server is OS-independent (net/http). SIGINT/SIGTERM stops it cleanly
// (closing the chunk store + image dir).
package main

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	"voila/internal/registry"
	"voila/internal/version"
)

// defaultListen is the documented default registry port (plan §4.3 / task
// spec). 7423 was chosen as a 4-digit port unlikely to clash with anything
// on a developer workstation.
const defaultListen = ":7423"

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := cli.NewFlagSet("voila-registry", "", os.Stderr)
	var (
		rootFlag    string
		listenFlag  string
		tlsCert     string
		tlsKey      string
		chunkOrigin string
		versionFlag bool
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&listenFlag, "listen", "", "TCP address to listen on (default: $PORT or :7423)")
	fs.StringVar(&tlsCert, "tls-cert", "", "TLS certificate PEM (enables HTTPS + HTTP/2; default: $VOILA_TLS_CERT)")
	fs.StringVar(&tlsKey, "tls-key", "", "TLS private key PEM (default: $VOILA_TLS_KEY)")
	fs.StringVar(&chunkOrigin, "chunk-origin", "", "public base URL chunks are served from, e.g. an S3/R2/CDN origin like https://cdn.example/bucket (default: $VOILA_CHUNK_ORIGIN; empty = registry-hosted at /v1/chunks/<id>)")
	fs.BoolVar(&versionFlag, "version", false, "print version and exit")
	if err := fs.Parse(args); err != nil {
		return 1
	}
	// Mirror `voila -version` / `voilad -version`: report the build stamp
	// (from `-ldflags -X` on voila/internal/version) before doing any work.
	// Cheap to satisfy before the chunk store / listener are opened.
	if versionFlag {
		fmt.Fprintln(os.Stdout, version.String())
		return 0
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: voila-registry [-root dir] [-listen addr] [-tls-cert cert] [-tls-key key] [-chunk-origin url]")
		return 2
	}
	root := cli.ResolveRoot(rootFlag, "")
	if err := os.MkdirAll(root, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "voila-registry: mkdir root: %v\n", err)
		return 1
	}

	// The registry serves chunks from the same LocalStore every other voila
	// binary uses, and ImageManifest blobs from <root>/images/.
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "voila-registry: open chunk store: %v\n", err)
		return 1
	}

	imageDir := filepath.Join(root, "images")
	// -chunk-origin wins; fall back to $VOILA_CHUNK_ORIGIN (PaaS injection);
	// empty means chunks are served by the registry itself (/v1/chunks/<id>).
	if chunkOrigin == "" {
		chunkOrigin = os.Getenv("VOILA_CHUNK_ORIGIN")
	}
	srv, err := registry.NewServer(store, imageDir, registry.WithChunkOrigin(chunkOrigin))
	if err != nil {
		_ = store.Close()
		fmt.Fprintf(os.Stderr, "voila-registry: new registry: %v\n", err)
		return 1
	}
	defer store.Close()

	chunkWhere := "registry-hosted (/v1/chunks/<id>)"
	if chunkOrigin != "" {
		chunkWhere = chunkOrigin
	}

	listenAddr := resolveListen(listenFlag)
	lis, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "voila-registry: listen %s: %v\n", listenAddr, err)
		return 1
	}

	cert, key := resolveTLS(tlsCert, tlsKey)
	if cert != "" && key == "" || cert == "" && key != "" {
		_ = lis.Close()
		fmt.Fprintln(os.Stderr, "voila-registry: -tls-cert and -tls-key must both be set (or both empty)")
		return 1
	}
	serveMode := "http"
	if cert != "" {
		serveMode = "https+h2"
	}

	fmt.Fprintf(os.Stderr, "registry listening on %s (%s) (root %s) (chunks: %s)\n", listenAddr, serveMode, root, chunkWhere)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	serveErr := make(chan error, 1)
	go func() {
		if cert != "" {
			serveErr <- srv.ServeTLS(lis, cert, key)
		} else {
			serveErr <- srv.Serve(lis)
		}
	}()

	if err := wait(sigCh, serveErr, lis); err != nil {
		fmt.Fprintf(os.Stderr, "voila-registry: %v\n", err)
		return 1
	}
	return 0
}

// resolveListen returns the address to listen on. If the -listen flag was
// explicitly set, it wins. Otherwise $PORT is honored (common for PaaS
// hosts such as Railway, Heroku, Fly), falling back to the documented
// default :7423.
func resolveListen(flag string) string {
	if flag != "" {
		return flag
	}
	if port := os.Getenv("PORT"); port != "" {
		return ":" + port
	}
	return defaultListen
}

// resolveTLS returns the (cert, key) pair to use for TLS. If the -tls-cert /
// -tls-key flags were set they win; otherwise $VOILA_TLS_CERT /
// $VOILA_TLS_KEY are honored (so a PaaS host can inject a cert without
// command-line flags). Empty/empty means serve plain HTTP (the default).
//
// When TLS is enabled, the stdlib http.Server automatically negotiates
// HTTP/2 (http2.ConfigureServer is called by ServeTLS when TLSConfig is
// nil), so a 64-way push fan-out multiplexes on a single TCP+TLS connection
// instead of opening 64. Railway terminates TLS at its edge and forwards
// HTTP/1.1 to the app, so this flag is for users serving TLS directly
// (bare metal, self-hosted) — behind Railway the edge already does h2 on
// the WAN leg.
func resolveTLS(certFlag, keyFlag string) (string, string) {
	if certFlag != "" || keyFlag != "" {
		return certFlag, keyFlag
	}
	return os.Getenv("VOILA_TLS_CERT"), os.Getenv("VOILA_TLS_KEY")
}

// wait blocks until either SIGINT/SIGTERM arrives (graceful shutdown: close
// the listener, drain the serve goroutine, return nil) or Serve returns an
// error (return that error).
func wait(sigCh <-chan os.Signal, serveErr <-chan error, lis net.Listener) error {
	select {
	case sig := <-sigCh:
		fmt.Fprintf(os.Stderr, "voila-registry: caught %v, shutting down\n", sig)
		// Closing the listener stops Serve; the deferred store.Close runs.
		_ = lis.Close()
		<-serveErr // drain
		return nil
	case err := <-serveErr:
		_ = lis.Close()
		return fmt.Errorf("serve: %w", err)
	}
}
