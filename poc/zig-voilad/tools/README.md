# voilad E2E bench tools

## Safety (read before running on a laptop / homelab)

Benches use `sudo`, `drop_caches`, FUSE, and NBD. **Do not start multiple drivers at once.**

- **Lock:** `VOILA_BENCH_LOCK` (default `/tmp/voilad-e2e-bench.lock`) — second runner exits immediately.
- **Timeouts:** every `bench-once` / `e2e_mount_bench` invocation is wrapped in `timeout(1)` (defaults: 90s FUSE, 120s Go EROFS, 90s Zig EROFS, 120s cold fetch). This prevents multi-hour 100% CPU when Zig EROFS walks a huge manifest tree on a sparse chunk store.
- **Cleanup:** `EXIT`/`INT`/`TERM` unmount bench mountpoints and disconnect NBD.

## Scripts

- `e2e_acceptance.sh` — four-backend **acceptance** suite (mount → hello/symlink/nested/multichunk/permissions → teardown). Uses `acceptance_cases.sh`, flock, and per-backend timeouts. Run Zig EROFS first; warm store recommended (`VOILA_ROOT=/tmp/voila-python313`).
- `e2e_fourway.sh` — cold fetch (capped) + 7×4 paths.
- `run_bench_quick.py` — warm store, 7×4 paths (set `VOILA_BENCH_SKIP_ZIG_EROFS=1` on large images if Zig EROFS is not yet rootfs-ready).
- `e2e_mount_bench/` — Go timing helper for FUSE/EROFS.
- `e2e_acceptance/` — Go mount driver for acceptance (FUSE/EROFS).

Example (warm store, safe defaults):

```bash
sudo VOILA_ROOT=/tmp/voila-python313 \
  VOILA_IMAGE='your-org/python:3.13' \
  python3 poc/zig-voilad/tools/run_bench_quick.py
```
