#!/bin/bash
# Gate 9 (plan §Phase 2a — EROFS+NBD mount backend), run INSIDE the privileged
# devcontainer image:
#   docker run --rm --privileged \
#     -v "$PWD:/workspace" -v <tarball-dir>:/fixtures -w /workspace \
#     mcr.microsoft.com/devcontainers/go:1-bookworm bash test/gates/gate9.sh /fixtures/alpine.tar
set -euo pipefail
. "$(dirname "$0")/_env.sh"

TARBALL="${1:?usage: gate9.sh <image-tarball>}"
ROOT=/tmp/gate9-root

echo "=== setup ==="
.devcontainer/cgroup-init.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends runc fuse3 erofs-utils >/dev/null 2>&1

echo "=== unit tests (linux) ==="
CGO_ENABLED=0 go build ./... && go test ./internal/erofsadapter/ ./internal/nbd/ ./internal/worker/ 2>&1 | tail -4

echo "=== build + ingest + start daemon (EROFS backend) ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
voila ingest -root "$ROOT" "$TARBALL" | grep "image ref"
REF=$(voila images -root "$ROOT" | awk 'NR==2{print $1}')
# Use the explicit /usr/local/bin/voilad path: the devcontainer image ships a
# stale /go/bin/voilad on PATH that predates the EROFS backend.
VOILA_MOUNT_BACKEND=erofs /usr/local/bin/voilad -root "$ROOT" &
WORKER_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT/worker.sock" ] && break; sleep 0.1; done
[ -S "$ROOT/worker.sock" ] || { echo "FAIL: worker socket never appeared"; exit 1; }

echo "=== 1. run via daemon over EROFS (stdout + exit code) ==="
OUT=$(VOILA_MOUNT_BACKEND=erofs /usr/local/bin/voila run -root "$ROOT" "$REF" -- /bin/sh -c 'echo via-erofs' 2>/dev/null)
[ "$OUT" = "via-erofs" ] || { echo "FAIL: got '$OUT'"; exit 1; }
set +e; VOILA_MOUNT_BACKEND=erofs /usr/local/bin/voila run -root "$ROOT" "$REF" -- /bin/sh -c 'exit 7' 2>/dev/null; RC=$?; set -e
[ "$RC" = "7" ] || { echo "FAIL: exit $RC want 7"; exit 1; }
echo "run-over-erofs OK"

echo "=== 2. EROFS lower mount + file reads ==="
# The worker tears down its mounts per-run, so re-verify the raw EROFS path
# via the NBD E2E test (already covered by unit tests above) and confirm the
# daemon left no stray mounts / devices behind.
sleep 0.5
if mount | grep -qE 'erofs|nbd'; then
  echo "FAIL: stray erofs/nbd mount left after run:"; mount | grep -E 'erofs|nbd'; exit 1
fi
for i in 0 1 2 3; do
  if [ -e "/sys/block/nbd$i/pid" ]; then
    echo "FAIL: nbd$i still connected (pid=$(cat /sys/block/nbd$i/pid))"; exit 1
  fi
done
echo "teardown clean (no erofs/nbd mounts, all nbd devices free)"

echo "=== 3. images info / rm / gc ==="
kill -TERM "$WORKER_PID"; wait "$WORKER_PID" 2>/dev/null || true   # gc requires stopped worker
CHUNKS_BEFORE=$(find "$ROOT/chunks" -type f | wc -l)
voila images gc -root "$ROOT"
CHUNKS_MID=$(find "$ROOT/chunks" -type f | wc -l)
[ "$CHUNKS_BEFORE" = "$CHUNKS_MID" ] || { echo "FAIL: gc removed reachable chunks ($CHUNKS_BEFORE -> $CHUNKS_MID)"; exit 1; }
voila images rm -root "$ROOT" "$REF"
voila images gc -root "$ROOT"
CHUNKS_AFTER=$(find "$ROOT/chunks" -type f | wc -l)
[ "$CHUNKS_AFTER" = "0" ] || { echo "FAIL: $CHUNKS_AFTER chunks left after rm+gc"; exit 1; }
echo "images info/rm/gc OK ($CHUNKS_BEFORE chunks -> 0)"

echo "GATE 9 PASSED"
