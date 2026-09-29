// Package main is the voila CLI entry point. It dispatches subcommands using
// the standard library flag package only (no cobra), as required by plan §2.
// Routing and help rendering come from the tiny declarative tree in
// internal/cli (command.go): the table below is the single source of truth
// for both, so help text can no longer voila from actual behavior. Each
// command still parses its own flags via cli.NewFlagSet.
//
// The CLI is a PURE CLIENT in the three-binary split (plan §12 / task 16): it
// owns local store operations (ingest / images / push / pull) and forwards
// container operations (run / exec / logs / ps / kill) to the `voilad` worker
// daemon over the worker socket. The FUSE mount, the runc launcher, and the
// registry server live in `voilad` / `voila-registry` respectively; this
// binary carries no daemon machinery.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"voila/internal/cli"
	"voila/internal/version"
)

// Config carries shared configuration passed to every subcommand. There is no
// global state; each subcommand receives a copy.
type Config struct {
	// Root is the voila data root directory. If empty, cli.ResolveRoot is used
	// (default /var/lib/voila).
	Root string
	// Socket is the worker daemon's unix socket path. If empty,
	// cli.ResolveSocket is used (default /var/run/voila.sock). Only the
	// daemon-talking subcommands (run/exec/logs/ps/kill) and `images gc` use it.
	Socket string
	// Stdout / Stderr are the writers used for user-facing output. They are
	// configurable so tests can capture output.
	Stdout io.Writer
	Stderr io.Writer
	// Stdin is the reader used for interactive prompts (currently only
	// `images prune`'s y/N confirmation). It is configurable so tests can
	// script answers.
	Stdin io.Reader
}

// subcommand is the dispatch signature every command implements.
type subcommand func(cfg Config, args []string) error

// wrap adapts a classic cmdX(cfg, args) command to a tree node whose Run
// receives only args (cfg is captured at tree-build time).
func wrap(cfg Config, run subcommand) func(args []string) error {
	return func(args []string) error { return run(cfg, args) }
}

// newRoot builds the command tree for cfg: one node per command, carrying
// the usage synopsis + short description that drive `voila`, `voila -h`,
// and `voila help <cmd>`. Package-level var so tests can stub the tree.
var newRoot = func(cfg Config) *cli.Command {
	return &cli.Command{
		Name: "voila",
		Footer: "the FUSE mount (`voilad mount`), the worker daemon (`voilad`), and the\n" +
			"registry server (`voila-registry`) are their own binaries.",
		Subs: []*cli.Command{
			{
				Name:  "ingest",
				Usage: "<tarball> [-ref override] [-platform os/arch] [-root dir]",
				Short: "ingest an OCI-layout or legacy docker-save tarball",
				Run:   wrap(cfg, cmdIngest),
			},
			{
				Name:  "import",
				Usage: "<ref> [-ref override] [-platform os/arch] [-root dir] [-user user] [-plain-http] [-push target] [-registry URL]",
				Short: "pull an image straight from an OCI registry (Docker Hub / quay.io / ghcr.io / …) and ingest it — no Docker daemon needed; -push publishes under your org in the same command",
				Run:   wrap(cfg, cmdImport),
			},
			imagesNode(cfg),
			{
				Name:  "run",
				Usage: "<ref-or-digest-prefix> [--] <cmd...> [-root dir] [-memory bytes] [-cpus pct]",
				Short: "run an ingested image via the `voilad` worker daemon (run `voilad -root <root>` first)",
				Run:   wrap(cfg, cmdRun),
			},
			{
				Name:  "exec",
				Usage: "<ctx-id> [--] <cmd...> [-root dir]",
				Short: "run an additional process in an existing context (daemon required)",
				Run:   wrap(cfg, cmdExec),
			},
			{
				Name:  "logs",
				Usage: "[-follow] <ctx-id> [-root dir]",
				Short: "replay (and optionally follow) a context's ring-buffered output",
				Run:   wrap(cfg, cmdLogs),
			},
			{
				Name:  "ps",
				Usage: "[-root dir]",
				Short: "list contexts known to the daemon",
				Run:   wrap(cfg, cmdPs),
			},
			{
				Name:  "kill",
				Usage: "[-signal N] <ctx-id> [-root dir]",
				Short: "signal a running context (default SIGTERM)",
				Run:   wrap(cfg, cmdKill),
			},
			{
				Name:  "push",
				Usage: "<ref-or-digest-prefix> [-registry URL] [-root dir] [-concurrency N]",
				Short: "upload an image's chunk closure + ImageManifest to a registry",
				Run:   wrap(cfg, cmdPush),
			},
			{
				Name:  "pull",
				Usage: "<ref> [-registry URL] [-root dir]",
				Short: "fetch an image's manifest from a registry (chunks stream on demand)",
				Run:   wrap(cfg, cmdPull),
			},
			{
				Name:  "login",
				Usage: "[registry-url] [-root dir]",
				Short: "save registry URL + API key to ~/.config/voila/credentials",
				Run:   wrap(cfg, cmdLogin),
			},
			{
				Name:  "logout",
				Usage: "",
				Short: "remove saved registry credentials",
				Run:   wrap(cfg, cmdLogout),
			},
			{
				Name:  "tag",
				Usage: "<src-ref-or-digest-prefix> <new-ref> [-root dir]",
				Short: "retag a locally ingested image without re-downloading (e.g. to push under your org)",
				Run:   wrap(cfg, cmdTag),
			},
			{
				Name:  "build",
				Usage: "[-f file] [-t ref] [--build-arg k=v] [--target name] [--no-cache] [context] [-root dir] [-socket path]",
				Short: "build an image from a classic Dockerfile (FROM/RUN/COPY/ENV/…)",
				Run:   wrap(cfg, cmdBuild),
			},
		},
	}
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	cfg := Config{
		Stdout: os.Stdout,
		Stderr: os.Stderr,
		Stdin:  os.Stdin,
	}
	if len(args) == 0 {
		fmt.Fprint(cfg.Stderr, newRoot(cfg).HelpText())
		return 2
	}
	name := args[0]
	// `-version` / `--version` is recognized before subcommand dispatch so
	// `voila -version` reports what you are running regardless of which
	// subcommand you might have meant to type. Pairs 1:1 with the same flag
	// on `voilad` and `voila-registry`; the value comes from
	// `voila/internal/version` (stamped via `-ldflags -X` by the release
	// pipeline and `make install`).
	if name == "-version" || name == "--version" {
		fmt.Fprintln(cfg.Stdout, version.String())
		return 0
	}
	root := newRoot(cfg)
	// `-h`/`--help`/`help [cmd...]` render help (general or per-command)
	// and succeed.
	if name == "-h" || name == "--help" {
		fmt.Fprint(cfg.Stdout, root.HelpText())
		return 0
	}
	if name == "help" {
		path := args[1:]
		node := root.Find(path)
		if node == nil {
			fmt.Fprintf(cfg.Stderr, "voila: unknown command %q\n\n", path[len(path)-1])
			fmt.Fprint(cfg.Stderr, root.HelpText())
			return 2
		}
		full := "voila"
		if len(path) > 0 {
			full = "voila " + strings.Join(path, " ")
		}
		fmt.Fprint(cfg.Stdout, node.HelpTextFor(full))
		return 0
	}
	if err := root.Execute(cfg.Stderr, args); err != nil {
		// An exitCodeError from `voila run` is propagated as the container's
		// exit code WITHOUT printing an error message — so running a failing
		// program through voila is indistinguishable from running it
		// directly. Only genuine infrastructure failures print "voila …".
		var exitErr *exitCodeError
		if errors.As(err, &exitErr) {
			return exitErr.Code
		}
		// Routing failures (unknown command / bare usage) already printed
		// their message + help; they map to the usage exit code.
		if errors.Is(err, cli.ErrUnknownCommand) || errors.Is(err, cli.ErrUsage) {
			return 2
		}
		fmt.Fprintf(cfg.Stderr, "voila %s: %v\n", name, err)
		return 1
	}
	return 0
}
