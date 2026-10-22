#!/usr/bin/env bash
# Empty-root registry run (see /cursor/stores/self/docs/zig-voilad-registry.md).
set -euo pipefail
unset VOILA_REGISTRY VOILA_SOCKET VOILA_REGISTRY_TOKEN

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_VOILAD="${ZIG_VOILAD:-$ROOT/zig-out/bin/zig-voilad}"
ZIG_FUSE="${ZIG_FUSE:-$ROOT/../zig-fuse/zig-out/bin/zig-fuse}"
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"
REG_ROOT="${REG_ROOT:-/tmp/voila-local-reg}"
REG_URL="${REG_URL:-http://127.0.0.1:7423}"
PROOF="${PROOF:-/tmp/zig-voilad-proof-registry-$(id -u)}"
IMAGE="${IMAGE:-test/alpine:zigproof}"

if ! curl -sf -o /dev/null "$REG_URL/v1/images/$IMAGE"; then
  echo "registry image missing at $REG_URL (prepare $REG_ROOT per zig-voilad-registry.md)" >&2
  exit 1
fi

sudo umount -R "$PROOF" 2>/dev/null || true
sudo rm -rf "$PROOF" 2>/dev/null || true
sudo mkdir -p "$PROOF" && sudo chown "$(id -un):$(id -gn)" "$PROOF"
printf '%s\n' "{\"registry\":\"$REG_URL\",\"token\":\"\"}" > "$PROOF/registry.creds"
chmod 600 "$PROOF/registry.creds"

CHUNKS_BEFORE=0
if [ -d "$PROOF/chunks" ]; then
  CHUNKS_BEFORE=$(find "$PROOF/chunks" -type f 2>/dev/null | wc -l)
fi
sudo "$ZIG_VOILAD" -root "$PROOF" -socket "$PROOF/worker.sock" -zig-fuse "$ZIG_FUSE" \
  > "$PROOF/voilad.log" 2>&1 &
DPID=$!
sleep 2
cleanup() { sudo kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; }
trap cleanup EXIT

set +e
OUT=$("$VOILA_BIN" run -root "$PROOF" "$IMAGE" -- /bin/echo zig-registry-ok 2>&1)
RC=$?
set -e
CHUNKS_AFTER=0
if [ -d "$PROOF/chunks" ]; then
  CHUNKS_AFTER=$(find "$PROOF/chunks" -type f 2>/dev/null | wc -l)
fi

echo "$OUT"
echo "exit=$RC chunks_before=$CHUNKS_BEFORE chunks_after=$CHUNKS_AFTER"

if echo "$OUT" | grep -q zig-registry-ok && echo "$OUT" | grep -q fetched: && [ "$CHUNKS_AFTER" -gt "$CHUNKS_BEFORE" ]; then
  echo "REGISTRY_PROOF=pass"
  exit 0
fi
echo "REGISTRY_PROOF=fail"
exit 1
