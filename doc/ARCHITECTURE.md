# Architecture

`voilad` is a single long-lived daemon per host. The `voila` CLI is a thin
gRPC client of that daemon (over a unix socket); containers themselves are
run by runc.

```
 voila run python:3.13 -- python -c 'print("hi")'
   │
   │ gRPC (unix socket)
   ▼
┌─────────────────────── voilad ───────────────────────┐
│                                                      │
│  1. read the image manifest        (local or registry)│
│  2. merge layers into one root manifest              │
│  3. build an EROFS metadata blob from it             │
│  4. serve data blocks over NBD, mount -t erofs       │
│  5. write an OCI runtime-spec bundle                 │
│                                                      │
│  chunk store ◀──── reads fetch missing chunks         │
│  (BLAKE3-verified)      from the registry on demand    │
└──────────────────────────┬───────────────────────────┘
                           ▼
                     runc runs the container
                     with the mount as its rootfs
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

## The EROFS + NBD combo

On Linux 5.15+ with `/dev/nbd*` available, `voilad` auto-selects EROFS+NBD
(`VOILA_MOUNT_BACKEND=auto`, the default). At mount time it builds a
deterministic EROFS metadata blob from the merged manifest tree, then serves
it through a userspace NBD device. EROFS is a read-only kernel filesystem;
its format lets voila point each file's data extents at fixed 1 MiB slots in
the virtual device. File bytes still live in the chunk store — only metadata
is in the blob.

When a process reads a file:

1. the kernel's EROFS driver asks the NBD device for the data block,
2. the daemon resolves the block to a chunk id,
3. it returns the chunk from the local store, fetching it from the registry
   first if needed (BLAKE3-verified).

Filesystem metadata is read by the kernel at native speed; file data crosses
NBD only for bytes actually touched.

**Build cost:** EROFS must describe the whole tree, so `erofsadapter.Build`
walks every path on each cold mount. That rebuild is **not cached today**
(despite older comments elsewhere — a known gap). Over a remote registry,
`Build` prefetches external subtree manifests in parallel (32-way BFS) so
network cold start stays around ~2 s. On a local store, large images can
spend seconds in `Build` before the container starts (see benchmarks below).
FUSE keeps lazy per-directory loading and is often faster for local cold
start on big trees, though sequential reads are slightly slower than EROFS.

If the host lacks EROFS or `/dev/nbd*`, the daemon falls back to FUSE with
the same lazy semantics. `VOILA_MOUNT_BACKEND=fuse` or `erofs` forces one
backend.

## Other components

**Ingest** (`voila import` / `voila ingest`): streaming tar parser over OCI
or docker-save images; decompression sniffed (raw/gzip/zstd); hardlinks share
an inode; whiteouts applied at the layer merge step. One-shot and eager;
everything afterwards is lazy.

**runc bundle**: `root.readonly: true`, env/args/cwd from the image config,
tmpfs on `/tmp`/`/var/tmp`/`/dev`/`/dev/shm`, default namespaces,
Docker-default capabilities; foreground `runc run`, so exit codes propagate.

**Worker API**: gRPC service (`Run`/`Exec`/`Logs`/`Events`/`List`/`Kill`)
over `/var/run/voila.sock`; output is kept in a byte-budget ring buffer with
replay+follow; a disconnecting client never kills a context.

**Registry** (`voila-registry`): HTTP server for chunks and manifests,
BLAKE3-verified PUTs. The wire protocol is documented in an
[OpenAPI 3.1 spec](../internal/registry/openapi.yaml) embedded in the binary
and self-served at `GET /openapi.yaml`. A registry may advertise a separate
chunk endpoint (`GET /v1/registry/config`) so reads can be served straight
from an S3/R2/CDN bucket. Auth is a bearer token (`VOILA_REGISTRY_TOKEN`);
empty means trusted network.

Earlier design notes lived in a separate plan file; this document is the
source of truth for current behavior.

## Benchmarks

Measured in the privileged devcontainer on real gate runs (see `git log`
and `test/gates/gate*.sh`). FUSE vs EROFS rows are 3-sample medians with
`drop_caches` and a fresh `voilad` each cold run.

| Scenario | Result |
|---|---|
| `python:3.13` `print("hi")` | 33 chunks / 9.4 MiB fetched = **0.9% of 1.05 GiB image** |
| `python:3.13` `import json,hashlib,sqlite3` | 72 chunks / 20.4 MiB = 1.9% |
| `postgres:16` initdb + server + SQL round trip | 169 chunks / 61.3 MiB = **13.6% of 452 MiB** |
| Cold-start over the network (empty machine, alpine) | **91 ms**, 5 chunks / 1.59 MiB (5.6% of image) |
| FUSE sequential read (gate 3 `dd`) | **714 MB/s** |
| `voila run` echo (warm, gate 4) | **12 ms** wall |
| alpine `echo hi` local cold start (drop_caches, fresh daemon) | FUSE **45 ms** / EROFS **241 ms** |
| `python:3.13` `print("hi")` local cold start | FUSE **147 ms** / EROFS **2.3 s** |
| `libpython` 28 MiB sequential `dd` | FUSE 362 MB/s / EROFS 415 MB/s |
| `python:3.13` ingest / re-ingest (gate 8) | 9.7 s cold; **0.68 s** re-ingest (7/7 layers cached) |
| One-file change in a 60 MiB image, push delta (gate 8) | **3 chunks / 3.3 KiB** uploaded |

## Limitations

- **Root required**: no user namespaces yet.
- **Linux-only runtime**: EROFS+NBD / FUSE + runc are Linux-only;
  import/chunkstore tests run on macOS but `voila run` needs privileged Linux.
- **EROFS local cold start**: first mount rebuilds metadata from scratch;
  can be much slower than FUSE on large images until build caching lands.
- **Registry auth is bearer-only, no TLS**: run behind a TLS-terminating
  reverse proxy for now.
- **Eager import**: `voila import` downloads and converts the whole image
  once; laziness starts after that.
- **Single node**: no cluster control plane.

What comes next: writable volumes, rootless mode, a custom kernel module
(`voilafs`), clustering. Not scheduled here — see open issues and commits.
