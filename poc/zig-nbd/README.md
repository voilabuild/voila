# Zig EROFS+NBD proof (poc)

**Claim:** a Zig 0.17 process using [zio](https://github.com/lalinsky/zio) and `std.Io` can serve the read-only NBD block device behind an EROFS mount. A read that crosses a 1 MiB chunk slot must return the correct bytes (byte `1048576` is `0xCC`, not zero).

The Go daemon already enforces this in `internal/nbd/backend_linux.go` and `TestE2E_MultiChunkBoundary`. This PoC reimplements only the NBD read path in Zig.

## What stayed in Go

- Building the EROFS metadata blob and slot layout (`erofsadapter.Build`), same tree as `TestE2E_MultiChunkBoundary`.
- The fixture writer under `fixture/` (`go run -tags zig_nbd_fixture`).

## Fixture layout

Written by the Go helper:

- `meta.bin` — patched EROFS metadata (`DeviceID=0`)
- `slots.txt` — `index chunk_hex` per 1 MiB slot
- `chunks/<hex>` — raw 1 MiB slot payloads (`0xAA`, `0xBB`, `0xCC`)

`dataOffset = len(meta.bin)`. Device size = `dataOffset + slot_count * 1 MiB`.

## Checks (pass bar)

On Linux as root with `modprobe nbd` and `/dev/nbd0`:

1. **Mount** — attach fixture read-only, `mount -t erofs` succeeds.
2. **Boundary** — `c.bin` bytes `0`, `1048575`, `1048576` are `0xAA`, `0xAA`, `0xCC`.
3. **Concurrency** — two slot loads in flight via zio `std.Io` (`Group.concurrent`).

Without root or `/dev/nbd0`, the command skips the mount and still runs `zig build test` (readAt span tests).

## Commands

From the voila repo root (Zig 0.17 on `PATH`):

```bash
cd poc/zig-nbd
zig build test
zig build && ./zig-out/bin/zig-nbd prove fixture-out
```

`prove` writes the fixture if missing, loads slots 0 and 2 concurrently, then mounts when root+nbd are available and prints the three boundary bytes.

Serve only (root):

```bash
zig build run -- serve fixture-out /dev/nbd0
```

## VM result (this agent run)

Non-root (`uid=1000`), no `/dev/nbd0` — root mount skipped; unit tests and concurrent slot load ran. See PR body for `zig build run -- prove` log.
