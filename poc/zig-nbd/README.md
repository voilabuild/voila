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

## Container test (privileged)

On a Linux host where `sudo modprobe nbd` works (module present in `/lib/modules/$(uname -r)`):

```bash
# from voila repo root
./poc/zig-nbd/container/run-prove.sh
```

The image installs Zig 0.17, Go, and `erofs-utils`, then runs `zig build test` and `zig-nbd prove` as root with `modprobe nbd` inside a **`docker run --privileged`** container.

**This cloud VM cannot pass the mount step:** the kernel image has no `nbd` module (`modprobe nbd` → “Module nbd not found”), including inside a privileged Ubuntu container (containers use the host’s module tree). Use a normal Linux VM or CI runner with `linux-modules-extra` / NBD enabled.

When NBD is missing, the container still runs `zig build test` and `zig-nbd prove` (readAt + concurrent slot load) and exits **2** so CI can distinguish “tests OK, mount not exercised” from a hard failure.

`run-prove.sh` uses `sudo docker` when the current user cannot access the Docker socket.

## VM result (this agent run)

Privileged container: **Zig build + unit tests pass** inside Ubuntu 24.04; **root mount not exercised** (`modprobe nbd` fails on kernel `6.12.94+`, no `/dev/nbd0`). Host non-root `prove` also skips mount.
