# Zig FUSE proof (poc)

**Claim:** a Zig 0.17 process using [zio](https://github.com/lalinsky/zio) and `std.Io` is the read-only filesystem behind a Linux kernel FUSE mount. A read that crosses a 1 MiB chunk boundary must return the correct bytes (byte `1048575` is `0xAA`, byte `1048576` is `0xCC`).

This PoC does not use go-fuse, image ingest, the worker socket, xattrs, statfs, or the EROFS/NBD path. macOS / FSKit are out of scope.

## What stayed in Go

The fixture writer under `fixture/` (`go run -tags zig_fuse_fixture`) emits a directory the Zig side reads. No image ingest.

Fixture layout:

- `chunks/a` — 1 MiB of `0xAA`
- `chunks/c` — 1 MiB of `0xCC`
- `tree.txt` — root contains file `big.bin` (2 MiB, chunk 0 = `a`, chunk 1 = `c`) and symlink `link` → `big.bin`

Zig does not rebuild the fixture.

## Checks (pass bar)

On Linux as root with `/dev/fuse`:

1. Root listing exposes `big.bin` and `link`
2. `readlink` of `link` is `big.bin`
3. `big.bin` bytes `1048575` and `1048576` are `0xAA` and `0xCC`
4. Opening `big.bin` for write returns `EROFS`

Without root or `/dev/fuse`, `prove` skips the mount and still runs `zig build test` (read walker span + hole tests).

## Commands

From the voila repo root (Zig 0.17 on `PATH`):

```bash
cd poc/zig-fuse
zig build test
zig build && ./zig-out/bin/zig-fuse prove fixture-out
```

`prove` writes the fixture if missing, then mounts when root and `/dev/fuse` are available. Concurrent chunk loads via zio are exercised in the read walker (`loadChunksConcurrent`); unit tests cover span and hole reads without FUSE.

Serve only (root):

```bash
zig build run -- serve fixture-out /tmp/zig-fuse-mnt
```

(Blocks in the FUSE read loop until unmount.)
