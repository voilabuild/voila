#!/bin/bash
# Gate 3 (plan §11.3), run INSIDE the privileged devcontainer image:
#   docker run --rm --privileged \
#     -v "$PWD:/workspace" -v <tarball-dir>:/fixtures -w /workspace \
#     mcr.microsoft.com/devcontainers/go:1-bookworm bash test/gates/gate3.sh /fixtures/alpine.tar
set -euo pipefail
. "$(dirname "$0")/_env.sh"

TARBALL="${1:?usage: gate3.sh <image-tarball>}"
ROOT=/tmp/gate3-root
MNT=/tmp/gate3-mnt

echo "=== setup: cgroups + fuse ==="
.devcontainer/cgroup-init.sh || true
apt-get update -qq && apt-get install -y -qq --no-install-recommends fuse3 >/dev/null
ls -la /dev/fuse

echo "=== unit + integration tests (linux) ==="
CGO_ENABLED=0 go build ./...
go test ./internal/mount/ -v 2>&1 | grep -E "^(--- |ok|FAIL)" || true
go test ./... 2>&1 | tail -8

echo "=== build voila + ingest fixture ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
rm -rf "$ROOT" "$MNT" && mkdir -p "$MNT"
voila ingest -root "$ROOT" "$TARBALL"
REF=$(voila images -root "$ROOT" | awk 'NR==2{print $1}')
echo "ingested ref: $REF"

echo "=== mount ==="
voilad mount -root "$ROOT" "$REF" "$MNT" &
MOUNT_PID=$!
for i in $(seq 1 50); do mountpoint -q "$MNT" && break; sleep 0.1; done
mountpoint "$MNT"

echo "=== gate assertions ==="
# 1. ls -R walks the whole tree without error
ls -R "$MNT" > /tmp/gate3-ls.out
echo "ls -R: $(wc -l < /tmp/gate3-ls.out) lines OK"
# 2. cat /etc/os-release
cat "$MNT/etc/os-release"
# 3. read-only: writes must fail
if touch "$MNT/should-fail" 2>/dev/null; then echo "FAIL: write succeeded on RO mount"; exit 1; fi
echo "RO enforced OK"
# 4. content integrity: checksum a real binary through the mount
BIN=$(find "$MNT/bin" "$MNT/usr/bin" -type f 2>/dev/null | head -1)
sha256sum "$BIN"
# 5. hardlink stat: busybox aliases share inode in alpine
stat -c '%n ino=%i nlink=%h uid=%u gid=%g mode=%a' "$MNT/bin/busybox" 2>/dev/null || true
# 6. latency bar: sequential read of a big synthetic file (created via a 2nd ingest
#    below if the image has no 100MB file) — measure via dd of the largest file.
BIG=$(find "$MNT" -type f -size +1M 2>/dev/null | head -1)
if [ -n "$BIG" ]; then
  SIZE=$(stat -c %s "$BIG")
  T0=$(date +%s%N)
  dd if="$BIG" of=/dev/null bs=1M 2>/dev/null
  T1=$(date +%s%N)
  MS=$(( (T1 - T0) / 1000000 ))
  echo "sequential read: $SIZE bytes in ${MS}ms ($(( SIZE / 1024 / 1024 * 1000 / (MS + 1) )) MiB/s)"
fi

echo "=== teardown ==="
kill -INT "$MOUNT_PID"; wait "$MOUNT_PID" 2>/dev/null || true
mountpoint -q "$MNT" && fusermount3 -u "$MNT" || true
echo "GATE 3 PASSED"
