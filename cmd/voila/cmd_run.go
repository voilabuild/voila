// cmd_run.go implements `voila run <ref-or-digest-prefix> [--] <cmd...>
// [-root dir] [-memory bytes] [-cpus pct]`. The CLI is a PURE CLIENT in the
// three-binary split: it forwards the run to the worker daemon (`voilad`),
// which owns the FUSE mount + runc lifecycle. When the daemon socket does not
// answer, the command surfaces a clear "no worker daemon" error.
//
// The exitCodeError contract is unchanged: a non-zero container exit code is
// returned via *exitCodeError and main.run surfaces it WITHOUT the standard
// "voila run: <err>" prefix, so running a failing program through voila is
// indistinguishable from running it directly.

package main

import (
	"errors"
	"fmt"
	"os"

	"voila/internal/cli"
)

// exitCodeError is returned by cmdRun when the container exits with a non-zero
// status. main.run unwraps it via errors.As and surfaces the code WITHOUT an
// enclosing "voila: <error>" message (so a `voila run` of a failing program
// is indistinguishable from running that program directly). It is the only
// error type cmdRun may return that main.run treats specially.
type exitCodeError struct {
	Code int
}

// Error implements error. The message is a short debug aid; main.run does not
// print this string (it inspects .Code directly via errors.As).
func (e *exitCodeError) Error() string {
	return fmt.Sprintf("voila: container exited %d", e.Code)
}

// cmdRun implements `voila run <ref-or-digest-prefix> [--] <cmd...> [-root
// dir] [-memory bytes] [-cpus pct]`. Resolution, mounting, and runc live in
// `voilad`; the CLI just shuttles stdin/stdout/stderr over the gRPC Run stream.
func cmdRun(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "run", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
		memoryFlag int64
		cpusFlag   int
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	fs.Int64Var(&memoryFlag, "memory", 0, "memory limit in bytes (0 = unlimited)")
	fs.IntVar(&cpusFlag, "cpus", 0, "CPU quota in core-percent (100 = one core; 0 = unlimited)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return errors.New("usage: voila run <ref-or-digest-prefix> [--] <cmd...> [-root dir] [-socket path] [-memory bytes] [-cpus pct]")
	}
	query := fs.Arg(0)
	cliArgs := fs.Args()[1:]
	// flag parsing stops at the first positional (the ref), so a "--"
	// separator after it is NOT consumed by fs.Parse — strip it here or it
	// becomes argv[0].
	cliArgs = stripLeadingDashDash(cliArgs)
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	if err := handoffRegistryCreds(cfg, rootFlag, socketFlag); err != nil {
		return fmt.Errorf("registry handoff: %w", err)
	}

	// Wire std streams. cfg.Stdout/Stderr may be nil (production os.*); the
	// daemon path forwards as-is.
	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}

	// Daemon-only: probe the worker socket. No answer → clear error. The
	// exitCodeError contract is preserved by runViaDaemon, which surfaces the
	// container's exit code as *exitCodeError.
	if err := cli.TryProbe(socket); err != nil {
		return errors.New("no worker daemon: start `voilad` first")
	}
	return runViaDaemon(cfg, socket, query, cliArgs, memoryFlag, cpusFlag, out, errOut)
}

// stripLeadingDashDash removes a single leading "--" separator from args if
// present, so a "--" passed by the user to disambiguate the trailing argv
// from the flag set's positional does NOT end up as argv[0] of the launched
// process. Used by `voila run` and `voila exec` (both client-side).
//
// flag.Parse already stops at the first non-flag positional; it does not
// consume a "--" that appears AFTER the first positional, hence this helper.
// A copy is taken so the caller's slice storage is not aliased by the
// returned slice (no accidental shared mutation when downstream code passes
// the returned slice to e.g. proto RunSpec.Args).
func stripLeadingDashDash(args []string) []string {
	if len(args) > 0 && args[0] == "--" {
		out := make([]string, len(args)-1)
		copy(out, args[1:])
		return out
	}
	return args
}
