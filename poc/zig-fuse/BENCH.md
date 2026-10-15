# FUSE read benchmark (VM, 2026-10-15)

One store: `/tmp/voila-bench-fuse`, image `bench:40m` with `/bench/large.bin` (40 MiB).
Go: `VOILA_MOUNT_BACKEND=fuse voilad mount -allow-other …`. Zig: `zig-fuse serve-index` on exported JSON.

Before each timed read: `sync` + `echo 3 | sudo tee /proc/sys/vm/drop_caches` (page cache only).

| Backend | Run 1 | Run 2 | Run 3 | Median |
|---------|-------|-------|-------|--------|
| go-fuse | 55.4 MiB/s | 328 MiB/s | 597 MiB/s | **328 MiB/s** (~344 MB/s) |
| zig-fuse | 426 MiB/s | 1176 MiB/s | 1333 MiB/s | **1176 MiB/s** (~1233 MB/s) |

Fairness: Zig does not BLAKE3-verify chunk blobs; Go’s chunkstore does on read.
Runs 2–3 are faster because in-process chunk caches survive `drop_caches`.
