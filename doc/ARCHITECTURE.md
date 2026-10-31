# Architecture

`voila` is one static, daemonless binary. Each command works directly on the
local store (`$VOILA_ROOT`); `voila run` and every build `RUN` step start a
rootless FUSE server for the image and run the command on top of it.

```
 voila run python:3.13 -- python -c 'print("hi")'
   │
   │ 1. resolve the ref to a root manifest chunk   (local, or pull the manifest)
   │ 2. start the FUSE server (container-fuse-serve) on that root, read-only
   │ 3. enter user + mount + PID namespaces, writable root over the mount,
   │    fresh /proc, minimal /dev, pivot_root
   │ 4. exec the command under a small init
   ▼
 FUSE reads ──▶ chunk store (BLAKE3-verified) ──▶ registry, only for missing chunks
```

## What is a manifest?

A manifest is a small protobuf tree that describes the image's filesystem:
each entry is a `File`, `Dir`, `Symlink` or `Device`. A file entry does not
contain data; it lists the chunk ids that hold its bytes, in order.

Subtrees larger than ~64 KiB are split into child manifests, themselves
stored as chunks. That keeps the top-level manifest tiny, so a container can
start after downloading only a few kilobytes of metadata.

## What is a chunk?

A chunk is a 1 MiB blob, addressed by the BLAKE3 hash of its raw bytes and
compressed with zstd when that helps. Chunks live in a flat local store
(`/var/lib/voila/chunks/ab/cd/<id>`) and on the registry under the same
address. Because the address is the content hash:

- identical data across images is stored once (dedup for free),
- every fetch can be integrity-checked,
- `voila push`/`pull` only move manifests up front; chunks stream on first
  touch.

## Other components

**Ingest** (`voila import` / `voila ingest`): streaming tar parser over OCI
or docker-save images; decompression sniffed (raw/gzip/zstd); hardlinks share
an inode; whiteouts applied at the layer merge step. One-shot and eager;
everything afterwards is lazy.

**Build** (`voila build`): a Dockerfile becomes a regular voila
image without tarballs or OCI blobs. The base image is mounted read-only with
the FUSE backend (image ids shown as the host ids they map to when a subuid
range is available), an unprivileged overlayfs on top captures each `RUN`'s
writes in an upper dir, and the command runs in the rootless sandbox described
below. The namespace maps 0 to the build user and 1..N to its `/etc/subuid`
range (`newuidmap`/`newgidmap`, run by the parent while the child waits on a
pipe), else just 0. After the command, the sandbox records the owner of every
non-root upper entry in an owners file and chowns it back to the build user so
the host can read it; the walk restores those owners and maps the remaining host
ids back (`core/idmap.zig`). The upper dir is walked straight
into a layer tree with the same chunking as ingest (0/0 char devices become
whiteouts, `user.overlay.opaque` marks opaque dirs) and merged over the
current tree; `COPY` walks the context the same way and needs no sandbox.
Steps are cached by `BLAKE3(parent root, instruction, env, inputs)`; a cache
hit only swaps the root chunk, so fully cached builds never load a tree.
Multi-stage builds run only the stages the target needs, in file order; each
stage ends as a root chunk. `COPY --from` loads the source tree's manifests
and grafts its nodes into the layer, reusing their chunk ids, and is keyed by
the source root chunk plus the paths. For `COPY --from=<image>` on a lazily
pulled image, the grafted chunk ids may not be local; push relies on the
registry already having them.

**Rootless sandbox** (`voila run`, build `RUN`; `runtime/oci/container_root.zig`):
a user, mount, PID and network namespace. PID 1 is a small voila init that runs the
command as PID 2, forwards signals to it, reaps orphans and exits with the
command's status (128 + signal when it is killed). `voila run` makes the
read-only FUSE root writable with an overlayfs whose upper and work dirs live
on disk in `<root>/containers/<id>/rw` (removed with the container); `voila
exec` and kernels that refuse the overlay get a read-only bind of the FUSE
root. The root gets a fresh `proc`, a tmpfs `/dev` with the host's `null`,
`zero`, `full`, `random`, `urandom` and `tty` bound in, a new `devpts`
instance (the `-it` terminal is allocated there and its master is passed back
over a unix socket) and a tmpfs `/dev/shm`. A fresh `sysfs` is mounted
read-only; if that is refused (no network namespace) the host's `/sys` is
bound read-only instead (`mount_setattr`, Linux 5.12+). Loopback is brought
up in the container netns so ports do not appear on the host. Outbound
traffic is `pasta` from the `passt` package when present (`--config-net`,
automatic port copy disabled). `-p` is implemented as pasta TCP mappings, or
a `setns` TCP proxy if pasta is missing. The process then `pivot_root`s into
the root and detaches the old one, so the host filesystem is no longer
mounted in the namespace; plain `chroot` is used only if `pivot_root` is
refused. The log file is opened before the root changes, so a non-`-it`
command's output lands in `container.log`.

**Registry client** (`voila push` / `pull` / `login`): speaks the `/v1` HTTP
wire protocol documented in [openapi.yaml](registry/openapi.yaml).
The standalone filesystem server (`voila-registry`) and the hosted Postgres/S3
service are maintained outside this release line — see branch
`backup/main-before-go-registry-move` and
[voilabuild/cloud-registry](https://github.com/voilabuild/cloud-registry).
Registries may advertise a separate chunk endpoint (`GET /v1/registry/config`)
so reads can be served from S3/R2/CDN. Auth is a bearer token
(`VOILA_REGISTRY_TOKEN`); empty means trusted network.

Earlier design notes lived in a separate plan file; this document is the
source of truth for current behavior.

## Benchmarks

These were measured on the Go release line (`voilad`, runc). They have not
been re-measured on the Zig CLI; treat them as history until the end-to-end
tests cover them.

| Scenario | Result |
|---|---|
| `python:3.13` `print("hi")` | 33 chunks / 9.4 MiB fetched = **0.9% of 1.05 GiB image** |
| `python:3.13` `import json,hashlib,sqlite3` | 72 chunks / 20.4 MiB = 1.9% |
| `postgres:16` initdb + server + SQL round trip | 169 chunks / 61.3 MiB = **13.6% of 452 MiB** |
| Cold-start over the network (empty machine, alpine) | **91 ms**, 5 chunks / 1.59 MiB (5.6% of image) |
| FUSE sequential read (`dd`) | **714 MB/s** |
| `voila run` echo (warm) | **12 ms** wall |
| alpine `echo hi` local cold start (drop_caches, fresh daemon) | **45 ms** |
| `python:3.13` `print("hi")` local cold start | **147 ms** |
| `libpython` 28 MiB sequential `dd` | 362 MB/s |
| `python:3.13` ingest / re-ingest | 9.7 s cold; **0.68 s** re-ingest (7/7 layers cached) |
| One-file change in a 60 MiB image, push delta | **3 chunks / 3.3 KiB** uploaded |

## Limitations

- **Linux only**: `voila run` and build `RUN` need `/dev/fuse` and
  unprivileged user namespaces (on Ubuntu 24.04+, the AppArmor profile from
  `install.sh`, which only covers the installed binary's path).
- **Registry auth is bearer-only, no TLS**: run behind a TLS-terminating
  reverse proxy for now.
- **Eager import**: `voila import` downloads and converts the whole image
  once; laziness starts after that.
- **One root manifest per image**: all metadata loads at start and is
  re-uploaded on any change (#78).
- **Single node**: no daemon, remote runtime or cluster control plane.
