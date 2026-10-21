# Zig FUSE proof (poc)

**Claim:** a Zig 0.17 process using [zio](https://github.com/lalinsky/zio) and `std.Io` implements the read-only VFS; **libfuse3** handles the Linux FUSE session and kernel protocol. A read that crosses a 1 MiB chunk boundary must return the correct bytes (byte `1048575` is `0xAA`, byte `1048576` is `0xCC`).

This PoC does not use go-fuse, image ingest, the worker socket, xattrs, statfs, or the EROFS/NBD path. macOS / FSKit are out of scope.

## Attached `run` (rootless, no voilad)

CLI commands dispatch through `src/runtime/` (`local` = in-process FUSE; `remote` = stub). Attached run mounts as the current user, execs one command, unmounts:

```bash
zig build
./zig-out/bin/zig-fuse run -root /path/to/store IMAGE_REF -- /usr/local/bin/python3 -c 'print("hello")'
```

`pull` and `images` use the runtime against `registry.creds` (Drift: `https://drift-registry-production.up.railway.app/registry` + token). Container lifecycle (`run` with `-d`, `--rm`, `--name`, `-e`, `-w`, `-v`, `-p`, `-it`, `ps`, `logs`, `exec`, `stop`, `rm`, `rmi`) is implemented on the local runtime.

Port publishing (`-p host:container`) runs `socat` on the host to forward `host` → `127.0.0.1:container`. Containers share the host network namespace (no iptables), so listeners bind on localhost like Docker’s `host` network mode.

## What stayed in Go

The fixture writer under `fixture/` (`go run -tags zig_fuse_fixture`) emits a directory the Zig side reads. No image ingest.

The `export/` tool (`go run -tags zig_fuse_export`) remains a **debug** JSON exporter; the primary mount path does not call it.

Fixture layout:

- `chunks/a` — 1 MiB of `0xAA`
- `chunks/c` — 1 MiB of `0xCC`
- `tree.txt` — root contains file `big.bin` (2 MiB, chunk 0 = `a`, chunk 1 = `c`) and symlink `link` → `big.bin`

Zig does not rebuild the fixture.

## Checks (pass bar)

The release binary is fully static (musl). It does not need `libfuse3.so`, `libsqlite3.so`, or `libcurl.so` on the host. Runtime still needs `/dev/fuse` and `fusermount3` for rootless mounts. `zig build` defaults to `-Dtarget=<arch>-linux-musl` and compiles libfuse 3.17.1 and the sqlite amalgamation into the binary. Registry HTTP uses `std.http`.

1. Root listing exposes `big.bin` and `link`
2. `readlink` of `link` is `big.bin`
3. `big.bin` bytes `1048575` and `1048576` are `0xAA` and `0xCC`
4. Opening `big.bin` for write returns `EROFS`

Without root or `/dev/fuse`, `prove` skips the mount and still runs `zig build test` (read walker span + hole tests, plus native loader tests when a store is present).

## Commands

From the voila repo root (`mise install` provisions Zig 0.17.0 on `PATH`):

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

(Blocks in `fuse_loop` until unmount.)

## Real voila store (native index)

Zig resolves an image ref via `images.db` and loads the manifest tree from the chunk store (same shape as `internal/imagestore` + `internal/mount`). Chunk blobs are read lazily (`algo=0` raw, `algo=1` zstd via vendored **static** libzstd). After decode, each chunk is checked with **BLAKE3-256 of the raw bytes** against the chunk id (same as `chunkstore.LocalStore.Get`), using the official [BLAKE3](https://github.com/BLAKE3-team/BLAKE3) C implementation (static, runtime SIMD dispatch).

```bash
# ingest once (voila CLI)
voila import -root /tmp/voila-store alpine:latest

cd poc/zig-fuse
zig build
sudo ./zig-out/bin/zig-fuse prove-store /tmp/voila-store alpine:latest
sudo ./zig-out/bin/zig-fuse serve-store /tmp/voila-store alpine:latest /tmp/mnt
```

`prove-store` loads the index in-process (no Go export), mounts, checks root listing, optional distro paths (`/etc/os-release`, busybox symlink `bin/arch` when present), and compares FUSE reads to the in-process VFS for nested files such as `/bench/large.bin` when present.

Real-image parity (Alpine-class store, diff vs Go userspace, exec, fair small-file bench): see `scripts/prove-real-image.sh` and `compare/` (`zig_fuse_compare` build tag). Bench requires `-zig-fuse-bin` and root: Go cold runs in a fresh process after `drop_caches`; Zig cold starts a new `serve-store` (empty chunk cache) after `drop_caches`.

PostgreSQL smoke (`postgres:16-alpine` rootfs on FUSE, PGDATA on tmpfs): `scripts/postgres-fuse-smoke.sh` (root; host `user_allow_other` in `fuse.conf`).

Legacy JSON path (debug export only):

```bash
go run -tags zig_fuse_export ./export -root /tmp/voila-store -image alpine:latest -o /tmp/zig-index.json
sudo ./zig-out/bin/zig-fuse serve-index /tmp/zig-index.json /tmp/mnt
```

## Build deps

- Zig 0.17
- Go toolchain (fixture writer and optional export tool)

libfuse, sqlite, zstd, and BLAKE3 are compiled into the binary. No system `-dev` packages.
