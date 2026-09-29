// Package main is the voilad entry point: the voila worker daemon plus the
// debug FUSE mount.
//
// voilad is the daemon-in-the-loop half of the three-binary split (plan §12 /
// task 16): it owns the gRPC Worker service (Run / Exec / Logs / Kill / List
// over <root>/worker.sock) and the platform-specific FUSE+runc launcher.
// The `voila` client talks to it over the unix socket; the CLI itself carries
// no daemon machinery.
//
// Default action (no subcommand) is the worker serve. `mount <ref>
// <mountpoint>` runs the debug FUSE mount (Linux only). On a non-Linux host
// voilad fails fast at runtime with "voilad requires linux": the worker
// internals + FUSE daemon are Linux-only by build tag, and there is no
// useful in-process behavior to fall back to.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"voila/internal/version"
)

// Config carries shared configuration passed to the worker / mount actions.
// mirror of cmd/voila's Config: the two binaries keep their own structs
// (neither wants the other's dispatch table).
type Config struct {
	Root   string
	Socket string
	Stdout io.Writer
	Stderr io.Writer
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	// `-version` / `--version` is handled before the onLinux() guard: a
	// freshly cross-compiled darwin `voilad` binary cannot serve (the worker
	// internals + FUSE daemon are Linux-only by build tag), but it should
	// still answer `voilad -version` so a release artifact can be verified
	// wherever it landed. The value is stamped via `-ldflags -X` into
	// `voila/internal/version`, identical to `voila` / `voila-registry`.
	if len(args) > 0 && (args[0] == "-version" || args[0] == "--version") {
		fmt.Fprintln(os.Stdout, version.String())
		return 0
	}
	// Non-Linux hosts have no useful behavior: the launcher is a stub and the
	// FUSE daemon is Linux-only. Fail fast with a clear message rather than
	// bringing up a daemon that can not actually launch a container.
	if !onLinux() {
		fmt.Fprintln(os.Stderr, "voilad requires linux")
		return 1
	}
	cfg := Config{
		Stdout: os.Stdout,
		Stderr: os.Stderr,
	}
	// Strip the optional `mount` subcommand word.
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		switch args[0] {
		case "mount":
			if err := cmdMount(cfg, args[1:]); err != nil {
				fmt.Fprintf(os.Stderr, "voilad mount: %v\n", err)
				return 1
			}
			return 0
		case "-h", "--help":
			usage(os.Stderr)
			return 0
		default:
			fmt.Fprintf(os.Stderr, "voilad: unknown subcommand %q\n", args[0])
			usage(os.Stderr)
			return 2
		}
	}
	// Default action: serve the worker.
	if err := cmdWorker(cfg, args); err != nil {
		fmt.Fprintf(os.Stderr, "voilad: %v\n", err)
		return 1
	}
	return 0
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: voilad [-root dir] [-socket path] [-registry URL]")
	fmt.Fprintln(w, "       voilad mount <ref-or-digest-prefix> <mountpoint> [-root dir] [-allow-other] [-registry URL]")
	fmt.Fprintln(w, "       voilad -version")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "default action: serve the voila worker daemon on /var/run/voila.sock")
	fmt.Fprintln(w, "  -root     voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fmt.Fprintln(w, "  -socket   worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	fmt.Fprintln(w, "  -registry registry URL for lazy chunk fetch + auto-pull (default: $VOILA_REGISTRY)")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "mount: temporarily mount an ingested image as a read-only FUSE view (debug use)")
}

// onLinux reports whether the current process is running on Linux. The choice
// is read at runtime — the binary compiles on every platform so the
// pre-built Linux artifact can be copied around, but it only does work on
// Linux.
func onLinux() bool { return cliGoos == "linux" }
