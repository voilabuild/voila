# voila

Run a container without downloading the whole image.

`python -c 'print("hi")'` on a typical image means pulling about a gigabyte
to use a few megabytes. voila splits images into content-addressed chunks and
mounts the rootfs lazily — file data is fetched only when something reads it.

Very early software. Expect breakage. Linux only; `voila` is one static,
daemonless binary that runs containers rootless.

## Try it

The install script downloads the release, verifies the checksum, installs
`voila`, sets up the AppArmor profile Ubuntu 24.04+ needs for unprivileged user
namespaces, and can wire up the hosted registry:

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh
```

More install flags: [doc/INSTALL.md](doc/INSTALL.md).

### Local run

```bash
voila import alpine:3.20
voila run --rm alpine:3.20 -- echo hi
voila run --rm -it alpine:3.20 sh
```

### Build

```bash
voila build -t myapp:1 .
voila run --rm myapp:1
```

`voila build` reads a Dockerfile, runs `RUN` steps rootless, and caches every
step; see [doc/CLI.md](doc/CLI.md#building-images).

### Hosted registry

The install script points at a free registry by default
(`https://drift-registry-production.up.railway.app`). Public pulls need no
account; chunks stream on first read. Sign up there to push under your org
(`<org>/alpine:3.20`). Push needs an API key (`voila login`, or
`VOILA_REGISTRY_TOKEN`).

```bash
voila push saucisse/alpine:3.20
# on another machine, empty store:
voila run saucisse/alpine:3.20 -- echo hi   # chunks fetch on read
```

### From source

```bash
mise install             # pinned zig
zig build -Doptimize=ReleaseFast
zig build test
```

See [doc/DEV_SETUP.md](doc/DEV_SETUP.md).

## How it works

1. **Import / build** — store 1 MiB BLAKE3 chunks plus a manifest tree.
2. **Mount** — a per-container FUSE server exposes the image read-only; a
   chunk is read (or fetched from the registry) only when a file needs it.
3. **Run** — the command runs in its own user, mount and PID namespaces on
   top of that mount, with writes going to a per-container directory.

## Docs

- [Architecture](doc/ARCHITECTURE.md) — how it fits together, benchmarks, limits
- [CLI](doc/CLI.md) — commands and flags
- [Testing](doc/TESTING.md)

## What's missing

TLS on the registry, multi-node, a daemon/remote runtime. Details in [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md).
