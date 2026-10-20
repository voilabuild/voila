# AGENTS.md

voila runs OCI images from a content-addressed chunk store (BLAKE3 ids, zstd blobs), mounted
through FUSE or EROFS+NBD. Linux only. Rules: [CONTRIBUTING.md](CONTRIBUTING.md). Design: [PRD](doc/zig/PRD-code-org.md).

## Migration state

- Zig is replacing Go. Do not add features to Go code (`cmd/`, `internal/`); the frozen copy lives on branch `main-legacy`.
- Until PRD phase 2 lands, Zig code lives in `poc/zig-fuse` (CLI), `poc/zig-nbd` (EROFS/NBD) and
  `poc/zig-voilad` (daemon). New code goes into the root layout from the PRD, not into `poc/`.

## Build & test

```
zig build && zig build test        # root workspace, no root needed
zig build test -Dprivileged        # needs root, /dev/fuse, nbd, erofs, runc
zig fmt --check .
```

Privileged and e2e failures in a sandbox are usually environmental. Reproduce them on a clean tree before investigating.

## Layers (dependencies point down; build.zig enforces it)

```
core, codec      pure, no I/O
sys, c           OS and C access, nothing else touches std.c
store, registry  data
mount, runtime   Backend / Runtime interfaces + implementations
daemon, cli, app app/ is the only place that picks implementations and reads env
```

## Adding an implementation (backend, launcher, transport…)

1. Create `src/<layer>/<impl>/` implementing that layer's interface.
2. Register it in `src/<layer>/impls.zig`.
3. Gate heavy deps behind a `-D<impl>` build option.

## Do not

- Use globals, call `getenv` in libraries, run `sh -c`, or use `anyerror` on public APIs.
- Write long comments, history comments, or banners (see CONTRIBUTING.md § Comments).
- Commit `zig-pkg/`, `.zig-cache/` or `zig-out/`.

## Docs

User-facing changes go in `doc/CLI.md`; architecture changes go in `doc/ARCHITECTURE.md`.

## Skills

`e2e-product-judge` (`.opencode/skills/e2e-product-judge/`): first-time-user evaluation. Load it before any product-evaluation task.
