# Contributing to voila

The full rationale is in [doc/zig/PRD-code-org.md](doc/zig/PRD-code-org.md). This page has the rules.

## Setup

```
mise install          # Zig 0.17.0
zig build
zig build test
```

Linux only. Privileged tests (`zig build test -Dprivileged`) need root, `/dev/fuse`, `nbd`, `erofs` and `runc`.

## Rules

- **Layout.** `src/<layer>/` for libraries, `cmd/<binary>/main.zig` for thin entry points. Interfaces sit at the directory root; implementations go in subdirectories.
- **Dependencies point down:** `core ← codec ← store/registry ← mount/runtime ← cli/app ← cmd`. `build.zig` will enforce this (#83); until then, review for it.
- **No globals, no `getenv` in libraries.** Pass `Io`, `Allocator` and config explicitly. Only `app/` reads the environment.
- **No shell.** Use `sys.process.run(argv)` or a syscall, never `sh -c`.
- **Errors.** Specific error sets on `pub` functions. A `catch {}` needs a reason. Libraries don't print.
- **Comments.** Default to none. One-line `///` on public API; `//` only to explain a *why*. No history, banners, commented-out code, or `TODO` without an issue number.
- **Size.** About 400 lines per file and 60 per function; going over needs a reason in the PR.
- **Deps.** Pin to a commit hash. Never commit `zig-pkg/`.

## Pull requests

- [ ] `zig fmt --check .`, `zig build` and `zig build test` pass
- [ ] Bug fixes include a failing-then-passing test
- [ ] User-facing changes update `doc/CLI.md`; architecture changes update `doc/ARCHITECTURE.md`
- [ ] No new dependency without a justification in the description
