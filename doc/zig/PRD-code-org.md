# PRD: Zig code organization & quality

Status: accepted · Owner: tech lead · Applies to: all Zig code on `main`

## 1. Why

voila is moving from Go to Zig and going open source. The Zig code today is three POCs
(`poc/zig-fuse`, `poc/zig-nbd`, `poc/zig-voilad`) that proved the approach but don't scale:

- Shared modules were copied and have drifted (`voila_tree`, `voila_store`, `posix_util`, `constants`, `voila_resolve`).
- `zig-voilad/build.zig` reaches into `../zig-fuse/src` and `../zig-nbd/src` by relative path.
- Each POC pins `zio` to `#main`, and each resolves it to a different hash.
- There is global mutable state (`runtime.io`, `g_voila_root`) and a fn-pointer hook (`backend.load_chunk_cached`) patched in at startup.
- Libraries read env vars (`VOILA_MOUNT_BACKEND`, `VOILA_RUNTIME`, `VOILA_NBD_DEV`).
- The code makes about 40 `sh -c` calls, some of them from a root daemon.

## 2. Goals

1. **Swap a part without touching the rest.** Mount backend (FUSE, EROFS+NBD, …), container
   runtime (runc, crun, …), store, registry client and daemon transport are each one interface
   with replaceable implementations.
2. **One workspace.** One `build.zig`, one dependency graph, no copies.
3. **Readable by a stranger.** A new contributor can find where a thing lives from the directory
   name and change it without reading unrelated code.
4. **Testable without root.** Everything above `sys/` runs against fakes in plain `zig build test`.

Non-goals:
- A local registry server. `voila-registry` is not ported; this repo ships only a registry client.
- Choosing the daemon RPC protocol. This PRD fixes only the `Transport` boundary.
- macOS support.

## 3. Layout

```
build.zig  build.zig.zon
src/
  core/      pure logic, no I/O: ChunkId, digest, hex, Manifest/Tree model, constants
  codec/     proto wire format, manifest proto/json, OCI json
  c/         translate-c shims: blake3.h zstd.h sqlite.h fuse.h
  sys/       the only code that touches std.c / std.os.linux: mount, process, fs
  store/     Store interface; local/ (sqlite + blob files); chunk cache
  registry/  Registry client interface; http/ (OCI, hub, creds, pull)
  mount/     Backend interface; fuse/; probe.zig
  runtime/   container Runtime interface; local/, remote/; oci/ (runc launcher)
  daemon/    contexts, lifecycle, events; transport/ interface
  cli/       argv parsing, command table, output formatting
  app/       composition root: Config -> concrete implementations
cmd/
  voila/main.zig     thin exe roots, < ~100 lines, no logic
  voilad/main.zig
test/e2e/  bench/  tools/
doc/
```

Naming:
- A file whose top level is a struct is `TitleCase.zig` (`Store.zig`, `Backend.zig`). Namespace files are `snake_case.zig`.
- No `voila_` prefixes. The module path is the namespace: `store.local`, not `voila_store`.
- A directory holds one concept. An interface lives at the directory root (`mount/Backend.zig`), and its implementations sit in subdirectories (`mount/fuse/`).

## 4. Dependency rule

```
core ← codec ← { store, registry } ← { mount, runtime } ← daemon ← { cli, app } ← cmd
                 sys, c: usable by every layer above codec
```

- Each layer is a named module in `build.zig`, and its `.imports` list names only the layers below it.
  An upward import fails to compile, so no linter is needed.
- `@import("../…")` across layers is banned. Import by module name.
- `core` and `codec` never import `sys`, `c` or `std.Io`. They stay pure and fast to test.

## 5. Extension points

There are five swappable boundaries:

| Interface | Implementations today | Next likely |
|---|---|---|
| `mount.Backend` | fuse | erofs+nbd (removed in #85), composefs, overlay |
| `runtime.Runtime` | local (in-proc), remote (daemon) | — |
| `runtime.oci.Launcher` | runc | crun, youki |
| `store.Store` | local | remote/cached tiers |
| `registry.Registry` | http (Drift/OCI) | — |
| `daemon.Transport` | grpc shim (behind `-Dgrpc`) | native Zig protocol (TBD) |

Rules:
- Interfaces use the `{ ptr: *anyopaque, vtable: *const VTable }` pattern, as in
  `poc/zig-fuse/src/runtime/iface.zig`. Each interface declares its own narrow `Error` set.
- Hot paths (per-chunk reads inside a backend) use comptime generics, not vtables.
- Every interface ships a fake in `<layer>/testing.zig` (in-memory store, no-op backend, …).
- Selection happens only in `app/`:
  - `app/` reads flags, env and config once, builds a `Config`, and passes it down.
  - Libraries never call `getenv`.
  - `mount/probe.zig` reports capabilities (kernel version, erofs, nbd, /dev/fuse); it does not pick a backend.

**Adding an implementation** (for example, a crun launcher):
1. Create `src/runtime/oci/crun/` implementing `Launcher`.
2. Add one line to `src/runtime/oci/impls.zig`.
3. If it pulls in a heavy dependency, gate it behind `-Dcrun=true` in `build.zig`.

No other file changes.

## 6. State, I/O, memory

- **No mutable globals.** `std.Io`, `Allocator` and config are passed explicitly. When there are too many, bundle them into one `Ctx` struct.
- **Allocators come from the caller.** Use an arena per request or CLI command.
- **Ownership shows in the name.** `alloc*`/`dupe*`/`read*Alloc` return memory the caller frees. Everything else borrows.
- Every acquire is followed by `errdefer` on the next line.
- **No shell.** Spawn processes with `sys.process.run(argv)` only. `sh -c`, `system()` and building command strings are banned. Use syscalls (`mount(2)`, `mkdir`), not `mount`/`mkdir -p` binaries.

## 7. Errors

- Use specific error sets on every `pub` function and vtable. `anyerror` is allowed only inside generic glue.
- A `catch {}` must carry a one-line comment saying why it is safe to ignore.
- `catch unreachable` is allowed only when the invariant is visible within a few lines.
- Libraries never print. User-facing detail goes into an optional `*Diagnostic` out-param, and `cli/` decides how to show it.

## 8. Comments

Good code mostly doesn't need comments. A comment is a cost the reader pays, so it has to buy something.

**Write:**
- `//!` at the top of a file: 1–2 lines on what this module owns.
- `///` on `pub` declarations of interfaces and public modules: one line (three at most). It covers
  only what the signature can't say: ownership, units, invariants, thread-safety.
- `//` inline: only a **why** the code can't express, such as a kernel/protocol quirk (with a link),
  a non-obvious invariant, or a workaround (with an issue link).

**Don't write:**
- A comment that restates the code.
- History ("added in #9", "was X before"). That's what git is for.
- Commented-out code.
- Banners and separators (`// ----- tests -----`).
- `TODO` without an issue: write `TODO(#123): …` or nothing.
- Essays. Anything over ~3 lines belongs in `doc/`.
- POC narration ("this proves that…").

**Examples from the POCs:**

Bad: it narrates who sets the hook and what it's for, and it exists only because of a global.
```zig
/// When set, store-backed slot loads use registry-aware local cache (zig-voilad).
pub var load_chunk_cached: ?*const fn (...) anyerror![]u8 = null;
```
Good: the global is gone; the dependency is a field, and the type explains itself.
```zig
store: store.Store,
```

Bad: a banner that adds nothing, since `test` blocks are already obvious.
```zig
// ----- unit tests (no root / FUSE) -----
```

Good: a cross-implementation invariant the reader can't infer.
```zig
// BLAKE3-256(payload), same as Go chunkstore.hash.
const id_hex = "96e67efc…";
```

Good: says why the shortcut is correct.
```zig
// Deterministic fake ids; slot assignment only needs uniqueness.
```

## 9. Size & style

- `zig fmt` is enforced in CI.
- Soft caps: ~400 lines per file and ~60 per function. Going over needs a reason in the PR description.
- `pub` only when another module uses it.
- `main.zig` holds no logic. Commands live in `cli/`, one file per command.

## 10. Tests

| Tier | Where | Command | Needs |
|---|---|---|---|
| unit | `test` blocks next to the code | `zig build test` | nothing |
| integration | `test` blocks using `testing.zig` fakes + temp dirs | `zig build test` | nothing |
| privileged | FUSE, user namespaces | `zig build test -Dprivileged` | root, Linux |
| e2e | `test/e2e/*.sh` | see `doc/TESTING.md` | root, built binaries |

- Tests use `std.testing.allocator`, so a leak fails the test.
- A bug fix comes with a test that fails without the fix.

## 11. Dependencies & hygiene

- Every dependency in `build.zig.zon` is pinned to a commit hash, never `#main` or a branch.
- `zig-pkg/`, `.zig-cache/` and `zig-out/` are never committed.
- New deps need a justification in the PR. We stay stdlib-leaning.
- C libraries are reached only through `src/c/` shims.
- Licensing: one root `LICENSE`, no per-file headers.

## 12. Migration

One PR per phase. Each phase preserves behavior and passes CI.

0. Docs: this PRD, `CONTRIBUTING.md`, `AGENTS.md`.
1. Freeze Go: branch `main-legacy` and tag `go-final` from `main`. `main` is not rewritten.
2. Root `build.zig` plus `core/` and `codec/`, deduplicated. For each copy pair, keep the superset and its tests.
3. `sys/`, `c/`, `store/`, `registry/`. Global hooks are replaced by injected interfaces.
4. `mount/`: fuse (from zig-fuse) and erofs_nbd (from zig-nbd) behind `Backend`, plus `probe.zig`.
5. `runtime/`, `cli/`, `app/`, `cmd/voila`. The binary is renamed `zig-fuse` → `voila`; release assets keep the old name for one release.
6. `daemon/`, `cmd/voilad`. The C++ gRPC shim becomes one `Transport` behind `-Dgrpc`.
7. Port e2e and bench, then delete `poc/zig-*`, all Go, and the Go CI jobs. The parity oracle builds from `main-legacy`.
