# voila

Run a container without downloading the whole image.

`python -c 'print("hi")'` on a typical image means pulling about a gigabyte
to use a few megabytes. voila splits images into content-addressed chunks and
mounts the rootfs lazily — file data is fetched only when something reads it.

Very early software. Expect breakage. `voila run` needs a privileged Linux
host with runc.

## Try it

On Linux, use the install script — it downloads the release, verifies the
checksum, installs `voila`, `voilad`, and `voila-registry`, and wires up the
hosted registry:

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sudo bash
```

Add `--with-systemd` to run `voilad` as a service, or start it by hand:

```bash
sudo voilad &
```

More install flags: [doc/INSTALL.md](doc/INSTALL.md).

### Local run

`voila import` stores images under the full Docker Hub ref. Use `voila tag`
for a short local name:

```bash
voila import alpine:3.20
voila tag registry-1.docker.io/library/alpine:3.20 alpine:3.20
voila run alpine:3.20 -- /bin/echo hi
```

### Hosted registry

The install script points at a free registry by default
(`https://drift-registry-production.up.railway.app`). Public pulls need no
account; chunks stream on first read. Sign up there to push under your org
(`<org>/alpine:3.20`). Push needs an API key (`--token` on install, or
`VOILA_REGISTRY_TOKEN`).

Publish an imported image:

```bash
voila tag registry-1.docker.io/library/alpine:3.20 saucisse/alpine:3.20
voila push saucisse/alpine:3.20
```

On another machine (empty store, same install + `voilad`):

```bash
voila pull saucisse/alpine:3.20          # manifest only
voila run saucisse/alpine:3.20 -- /bin/echo hi   # chunks fetch on read
```

Cold start over the hosted registry on alpine has measured around 91 ms.
A `python:3.13` `"hi"` run touches about 0.9% of the image.

### From source

```bash
go install ./cmd/...
voila import -root /tmp/voila python:3.13
voilad -root /tmp/voila &
voila run -root /tmp/voila python:3.13 -- python -c 'print("hi")'
```

Devcontainer: [doc/DEV_SETUP.md](doc/DEV_SETUP.md).

## How it works

1. **Import** — pull from any OCI registry; store 1 MiB BLAKE3 chunks + a manifest.
2. **Mount** — `voilad` serves the rootfs via EROFS+NBD (FUSE if the host lacks that).
3. **Run** — hand an OCI bundle to runc.

## Docs

- [Architecture](doc/ARCHITECTURE.md) — how it fits together, benchmarks, limits
- [CLI](doc/CLI.md) — commands and flags

## What's missing

Writable layers, rootless runs, TTY, TLS on the registry, multi-node. Root is
required today. Details in [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md).
