// Package cli holds the small cross-binary helpers shared by voila's three
// command binaries (voila, voilad, voila-registry): root / socket resolution,
// the worker-dial probe, a flag-set constructor, and the human-readable
// byte/time/digest renderers.
//
// It is intentionally tiny and boring — the per-binary cmd packages remain
// the locus of behavior; this package exists purely so the three binaries do
// not each ship a private copy of the same dozen lines.
package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	voilapb "voila/internal/proto"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// SocketName is the file under the voila root the worker daemon listens on.
// (kept for backwards reference)
const SocketName = "worker.sock"

// DefaultRoot is the voila data root used when no -root flag and no $VOILA_ROOT
// are set. It mirrors Docker's /var/lib/docker: a system-wide, root-owned
// location for the content-addressed chunk store + image manifests. A
// non-root user overrides it with $VOILA_ROOT (e.g. ~/.voila) or -root.
const DefaultRoot = "/var/lib/voila"

// DefaultSocket is the worker daemon's unix socket path used when no -socket
// flag and no $VOILA_SOCKET are set. It mirrors Docker's /var/run/docker.sock:
// decoupled from the data root so the socket lives in the conventional runtime
// directory, not under the data tree. Override with $VOILA_SOCKET or -socket.
const DefaultSocket = "/var/run/voila.sock"

// ErrWorkerDown is the sentinel returned by DialWorker / TryProbe when the
// daemon socket is absent or no daemon answers. Wrap sites add the socket
// path details; callers may errors.Is against this to distinguish "daemon
// down / stale socket" from a transient I/O failure.
//
// The wording surfaces in user-facing errors, hence the actionable hint.
var ErrWorkerDown = fmt.Errorf("voila daemon is not running (start it with `voilad`)")

// ResolveRoot returns the voila root. Precedence:
//  1. explicit (a -root flag value), if non-empty
//  2. fallback (caller-supplied default, typically empty), if non-empty
//  3. $VOILA_ROOT, if set
//  4. DefaultRoot ("/var/lib/voila")
func ResolveRoot(explicit, fallback string) string {
	if explicit != "" {
		return explicit
	}
	if fallback != "" {
		return fallback
	}
	if env := os.Getenv("VOILA_ROOT"); env != "" {
		return env
	}
	return DefaultRoot
}

// RootExplicit reports whether the user explicitly chose a data root, either
// via a non-empty -root flag or $VOILA_ROOT. It is the signal ResolveSocket
// uses to decide between the legacy "<root>/worker.sock" socket and the
// decoupled default /var/run/voila.sock: an explicit root pins the socket
// under it (back-compat), the default root uses the system socket.
func RootExplicit(rootFlag string) bool {
	return rootFlag != "" || os.Getenv("VOILA_ROOT") != ""
}

// ResolveSocket returns the worker daemon's unix socket path. Precedence:
//  1. explicit (a -socket flag value), if non-empty
//  2. fallback (caller-supplied default, typically empty), if non-empty
//  3. $VOILA_SOCKET, if set
//  4. if the user explicitly chose a data root (rootExplicit, via -root or
//     $VOILA_ROOT), the legacy "<root>/worker.sock" — so existing
//     `voilad -root X` + `voila run -root X` workflows keep working
//  5. DefaultSocket ("/var/run/voila.sock")
//
// The socket is decoupled from the data root by default (mirroring Docker's
// /var/run/docker.sock vs /var/lib/docker), so the CLI finds the daemon
// without knowing where its data lives. The root-pinned fallback preserves
// the pre-decoupling behaviour for users who still pass -root.
func ResolveSocket(explicit, fallback string, rootExplicit bool, resolvedRoot string) string {
	if explicit != "" {
		return explicit
	}
	if fallback != "" {
		return fallback
	}
	if env := os.Getenv("VOILA_SOCKET"); env != "" {
		return env
	}
	if rootExplicit {
		return filepath.Join(resolvedRoot, SocketName)
	}
	return DefaultSocket
}

// SocketPath returns the legacy "<root>/worker.sock" path. It is retained for
// callers that deliberately co-locate the socket with the data root (e.g.
// tests that want a self-contained temp root). Production paths use
// ResolveSocket, which defaults to /var/run/voila.sock independently of root.
func SocketPath(root string) string {
	return filepath.Join(root, SocketName)
}

// DialWorker opens a WorkerClient over the unix socket at socketPath. If the
// socket file is absent, or no daemon answers within probeTimeout, DialWorker
// returns a wrapped ErrWorkerDown so the caller can surface a clear "is
// `voilad` running?" message.
//
// The returned conn must be Close()d by the caller.
func DialWorker(socketPath string) (*grpc.ClientConn, voilapb.WorkerClient, error) {
	conn, err := dialWorkerConn(socketPath)
	if err != nil {
		return nil, nil, fmt.Errorf("%w (socket=%s)", ErrWorkerDown, socketPath)
	}
	return conn, voilapb.NewWorkerClient(conn), nil
}

// dialWorkerConn dials the worker at the supplied absolute socket path with
// insecure creds (the socket is local-only) and a 2s fail-fast deadline.
func dialWorkerConn(path string) (*grpc.ClientConn, error) {
	// Fail fast when the socket file is absent: there is no daemon to wait for.
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: socket %q does not exist", ErrWorkerDown, path)
		}
		return nil, err
	}
	// grpc.NewClient is non-blocking; we therefore perform a tiny connect
	// probe (a 1-byte write + read on the socket) before declaring success so
	// that a stale-but-present socket is caught here rather than as a silent
	// hung-first-RPC.
	probeCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := probeUnixSocket(probeCtx, path); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrWorkerDown, err)
	}
	conn, err := grpc.NewClient(
		"unix://"+path,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

// probeUnixSocket opens a connection to the unix socket at path, returns nil
// once it accepts, and closes the connection immediately. The purpose is to
// detect an absent listener behind a present socket file.
func probeUnixSocket(ctx context.Context, path string) error {
	d := net.Dialer{}
	c, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return err
	}
	_ = c.Close()
	return nil
}

// TryProbe returns nil if a daemon answers on socketPath and a non-nil error
// otherwise. It is used by `voilad worker` to detect a stale socket (so it can
// remove it) and by `voila run` to decide whether the daemon path is
// available, and by `voila images gc` to refuse running while a daemon holds
// chunk references. The error wraps ErrWorkerDown so callers can errors.Is.
func TryProbe(socketPath string) error {
	if _, err := os.Stat(socketPath); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%w: socket %q does not exist", ErrWorkerDown, socketPath)
		}
		return err
	}
	probeCtx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if err := probeUnixSocket(probeCtx, socketPath); err != nil {
		return fmt.Errorf("%w: %v", ErrWorkerDown, err)
	}
	return nil
}

// NewFlagSet returns a FlagSet configured for the voila CLI conventions
// (errors go to the provided writer, usage message on a parse error). progName
// is the program name shown in the usage line ("voila" / "voilad" /
// "voila-registry"); cmdName is the sub-command name ("run", "ingest", …) or
// "" for a single-command binary (the usage line then collapses to
// "usage: <progName> ...").
func NewFlagSet(progName, cmdName string, errOut io.Writer) *flag.FlagSet {
	name := cmdName
	if name == "" {
		name = progName
	}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	if errOut != nil {
		fs.SetOutput(errOut)
	} else {
		fs.SetOutput(os.Stderr)
	}
	fs.Usage = func() {
		if cmdName != "" {
			fmt.Fprintf(fs.Output(), "usage: %s %s ...\n", progName, cmdName)
		} else {
			fmt.Fprintf(fs.Output(), "usage: %s ...\n", progName)
		}
		fs.PrintDefaults()
	}
	return fs
}

// ShortDigest renders the leading 12 hex chars of a digest, or "-" when the
// digest slice is empty.
func ShortDigest(d []byte) string {
	if len(d) == 0 {
		return "-"
	}
	const want = 12
	out := fmt.Sprintf("%x", d)
	if len(out) > want {
		out = out[:want]
	}
	return out
}

// FormatTime renders a Unix-nanosecond timestamp as a UTC "RFC3339-ish"
// string, or "-" when ns is non-positive (the "missing / not yet" sentinel).
func FormatTime(ns int64) string {
	if ns <= 0 {
		return "-"
	}
	return time.Unix(0, ns).UTC().Format("2006-01-02T15:04:05Z")
}

// FormatBytes renders a byte count using KiB / MiB / GiB / TiB units.
func FormatBytes(n uint64) string {
	const (
		KiB = 1 << 10
		MiB = 1 << 20
		GiB = 1 << 30
		TiB = 1 << 40
	)
	switch {
	case n >= TiB:
		return fmt.Sprintf("%.2f TiB", float64(n)/float64(TiB))
	case n >= GiB:
		return fmt.Sprintf("%.2f GiB", float64(n)/float64(GiB))
	case n >= MiB:
		return fmt.Sprintf("%.2f MiB", float64(n)/float64(MiB))
	case n >= KiB:
		return fmt.Sprintf("%.2f KiB", float64(n)/float64(KiB))
	default:
		return fmt.Sprintf("%d B", n)
	}
}
