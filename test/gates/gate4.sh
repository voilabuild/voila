#!/bin/bash
# Gate 4 (plan §11.4), run INSIDE the privileged devcontainer image:
#   docker run --rm --privileged \
#     -v "$PWD:/workspace" -v <tarball-dir>:/fixtures -w /workspace \
#     mcr.microsoft.com/devcontainers/go:1-bookworm bash test/gates/gate4.sh /fixtures/alpine.tar
set -euo pipefail
. "$(dirname "$0")/_env.sh"

TARBALL="${1:?usage: gate4.sh <image-tarball>}"
ROOT=/tmp/gate4-root

echo "=== setup ==="
.devcontainer/cgroup-init.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends runc fuse3 >/dev/null 2>&1
runc --version | head -1

echo "=== unit tests (linux) ==="
CGO_ENABLED=0 go build ./...
go test ./internal/runtime/ ./internal/mount/ 2>&1 | tail -3

echo "=== build + ingest ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
voila ingest -root "$ROOT" "$TARBALL" | grep "image ref"
REF=$(voila images -root "$ROOT" | awk 'NR==2{print $1}')

# `voila run` is daemon-only since the three-binary split: start voilad.
voilad -root "$ROOT" >/tmp/gate4-voilad.log 2>&1 &
VOILAD_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT/worker.sock" ] && break; sleep 0.1; done
[ -S "$ROOT/worker.sock" ] || { echo "FAIL: voilad socket never appeared"; cat /tmp/gate4-voilad.log; exit 1; }

echo "=== gate 4 assertions ==="
# 1. stdout through the container + tmpfs /tmp exists
OUT=$(voila run -root "$ROOT" "$REF" -- /bin/sh -c 'echo hi; ls -d /tmp')
echo "$OUT"
[ "$(echo "$OUT" | head -1)" = "hi" ] || { echo "FAIL: expected hi"; exit 1; }
echo "$OUT" | grep -q '^/tmp$' || { echo "FAIL: /tmp missing"; exit 1; }

# 2. exit code propagation
set +e
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'exit 7'
RC=$?
set -e
[ "$RC" = "7" ] || { echo "FAIL: exit code $RC, want 7"; exit 1; }
echo "exit-code propagation OK (7)"

# 3. tmpfs non-persistence across runs
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'touch /tmp/foo && test -e /tmp/foo'
set +e
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'test -e /tmp/foo'
RC=$?
set -e
[ "$RC" != "0" ] || { echo "FAIL: /tmp/foo persisted across runs"; exit 1; }
echo "tmpfs non-persistence OK"

# 4. rootfs is writable (overlay copy-up over the RO FUSE lower) but
# ephemeral: a write succeeds in-run, but does not persist across runs
# (upper+work are torn down with the context). Mirrors the tmpfs upper
# surface's ephemeral semantics, just covering the whole rootfs so image
# entrypoints that chmod/write their own root (postgres, apt install, …)
# work.
set +e
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'touch /copied-up && test -e /copied-up'
RC=$?
set -e
[ "$RC" = "0" ] || { echo "FAIL: write to rootfs failed (expected writable overlay)"; exit 1; }
set +e
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'test -e /copied-up'
RC=$?
set -e
[ "$RC" != "0" ] || { echo "FAIL: /copied-up persisted across runs"; exit 1; }
echo "writable+ephemeral rootfs OK"

# 5. env from image config (PATH present), private netns has only lo
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'test -n "$PATH"'
LO=$(voila run -root "$ROOT" "$REF" -- /bin/sh -c 'ls /sys/class/net')
[ "$LO" = "lo" ] || { echo "FAIL: expected only lo, got: $LO"; exit 1; }
echo "env + private netns OK"

# 6. no leftover mounts or ctx dirs
if mount | grep -q voilafs; then echo "FAIL: leftover voilafs mounts"; mount | grep voilafs; exit 1; fi
if [ -n "$(ls -A "$ROOT/ctx" 2>/dev/null)" ]; then echo "FAIL: leftover ctx dirs"; ls "$ROOT/ctx"; exit 1; fi
echo "teardown clean OK"

# 7. time-to-first-byte (informational, plan §11.6 sub-second bar)
T0=$(date +%s%N)
voila run -root "$ROOT" "$REF" -- /bin/echo warm >/dev/null
T1=$(date +%s%N)
echo "wall-clock run(echo): $(( (T1 - T0) / 1000000 ))ms"

kill -TERM "$VOILAD_PID"; wait "$VOILAD_PID" 2>/dev/null || true
echo "GATE 4 PASSED"
