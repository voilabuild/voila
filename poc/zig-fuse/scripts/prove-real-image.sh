#!/usr/bin/env bash
# Prove Zig FUSE on a real voila store image: diff vs Go, exec, fair bench.
set -euo pipefail

VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-real-image-proof}"
IMAGE_REF="${IMAGE_REF:-registry-1.docker.io/library/alpine:3.20}"
MNT="${MNT:-/tmp/zig-fuse-real-image-mnt}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ZIG_FUSE="$REPO_ROOT/poc/zig-fuse"
ZIG_BIN="${ZIG_BIN:-zig}"

VOILA_BIN="${VOILA_BIN:-$(cd "$REPO_ROOT" && go build -o /tmp/voila-proof ./cmd/voila && echo /tmp/voila-proof)}"

cleanup() {
  if mountpoint -q "$MNT" 2>/dev/null; then
    fusermount3 -u "$MNT" 2>/dev/null || umount "$MNT" 2>/dev/null || true
  fi
  if [[ -n "${SERVE_PID:-}" ]] && kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$VOILA_ROOT"
if ! "$VOILA_BIN" images -root "$VOILA_ROOT" 2>/dev/null | grep -q alpine; then
  "$VOILA_BIN" import -root "$VOILA_ROOT" "$IMAGE_REF"
fi

cd "$ZIG_FUSE"
"$ZIG_BIN" build
ZIG_FUSE_BIN="$ZIG_FUSE/zig-out/bin/zig-fuse"
COMPARE_BIN="${COMPARE_BIN:-/tmp/zig-fuse-compare}"
(cd "$REPO_ROOT" && go build -tags zig_fuse_compare -o "$COMPARE_BIN" ./poc/zig-fuse/compare)

echo "=== prove-store ==="
sudo "$ZIG_FUSE_BIN" prove-store "$VOILA_ROOT" "$IMAGE_REF"

echo "=== fair bench (go: new process; zig: new serve-store per cold) ==="
sudo "$COMPARE_BIN" -bench -root "$VOILA_ROOT" -image "$IMAGE_REF" -mount "$MNT" \
  -zig-fuse-bin "$ZIG_FUSE_BIN"

sudo rm -rf "$MNT"
sudo mkdir -p "$MNT"
sudo "$ZIG_FUSE_BIN" serve-store "$VOILA_ROOT" "$IMAGE_REF" "$MNT" &
SERVE_PID=$!
for _ in $(seq 1 100); do
  if sudo test -f "$MNT/etc/os-release"; then break; fi
  sleep 0.1
done

echo "=== diff (Go userspace vs Zig FUSE) ==="
sudo "$COMPARE_BIN" -root "$VOILA_ROOT" -image "$IMAGE_REF" -mount "$MNT"

echo "=== exec /bin/true from mount ==="
EXEC_OUT=$(sudo chroot "$MNT" /bin/true; echo "exit=$?")
echo "chroot $MNT /bin/true -> $EXEC_OUT"
