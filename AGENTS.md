# AGENTS.md

Notes for coding agents (and humans) working in this repo.

## What this is

**voila** is a container tool that ingests OCI / `docker save` images into a
content-addressed chunk store (BLAKE3-addressed, zstd-compressed blobs) and
runs them via EROFS+NBD or FUSE. Three binaries: `voila` (client CLI),
`voilad` (root worker daemon, Linux-only), `voila-registry` (unprivileged
HTTP server). Pre-alpha; Go only, stdlib-leaning by design.

## Build & test

```
go build ./...
go test ./...
go test ./cmd/voila -run TestImagesPrune -v   # single package/test
```

Known environment-dependent failures on macOS dev machines (not yours to
"fix" blindly): `cmd/voilad` socket-mode tests and `internal/ocireg`
platform-default tests. Verify a failure pre-exists on a clean tree before
investigating.

## CLI conventions (important)

The CLI uses **stdlib `flag` only — no cobra/urfave/kong** (plan §2). Routing
and help come from the tiny declarative tree in `internal/cli/command.go`
("light cobra"). To add or change a command:

1. **Register it in the tree**, not in prose: top-level commands live in
   `newRoot()` in `cmd/voila/main.go`; `voila images` subcommands live in
   `imagesSubSpecs` in `cmd/voila/images.go`. The `Name`/`Usage`/`Short`
   fields ARE the help output — there is no hand-written usage text to edit,
   and none should be introduced.
2. **Commands parse their own flags** with `cli.NewFlagSet(prog, name, w)`
   and keep the signature `func(cfg Config, args []string) error`. The tree
   routes argv words; it does not parse flags.
3. **Scope flags to their owner.** Subcommand-specific flags are declared
   only for that subcommand's flag set (see how `prune`'s `-f` is declared).
4. Use the shared helpers instead of re-rolling them: `cli.ResolveRoot`,
   `cli.ResolveSocket`, `cli.TryProbe` (refuse destructive store operations
   while the daemon answers), `cli.FormatBytes`/`FormatTime`/`ShortDigest`.
5. Interactive prompts read from `cfg.Stdin` (testable); user-facing output
   goes through `cfg.Stdout`/`cfg.Stderr`.

## Store layer

- Chunks: content-addressed (`internal/chunkstore`). Deletion policy:
  `GC(reachable)` for mark-and-sweep reclaim, `PruneAll()` for total wipe.
  Both delete index row + blob file together.
- Images: `internal/imagestore` owns `<root>/images.db` + `<root>/images/*.pb`.
- Destructive store ops must guard with `cli.TryProbe(socket)` and refuse
  while a daemon is running.

## Testing patterns

- Package-internal tests, table-style where natural; temp roots via
  `t.TempDir()`.
- In cmd/voila tests, reuse `ingestTinyFixture(t, ref)` /
  `countChunksFiles(t, root)` (cmd_daemon_test.go) for store fixtures.
- Dispatch/help behavior is tested in `internal/cli/command_test.go`; stub
  the command tree by swapping the `newRoot` var (see cmd_run_test.go).

## Docs

User-facing command changes must update `doc/CLI.md`; anything that alters
the architecture belongs in `doc/ARCHITECTURE.md`.

## Skills

- `e2e-product-judge` (`.opencode/skills/e2e-product-judge/`): judge voila as
  a first-time user — install fresh, walk documented flows, probe negative
  paths, and report ranked findings with repro commands. Load it before any
  product-evaluation task.
