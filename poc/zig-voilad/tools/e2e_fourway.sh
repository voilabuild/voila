#!/usr/bin/env bash
# Four-way E2E mount bench: Zig EROFS/FUSE + Go EROFS/FUSE.
# Requires root (drop_caches, FUSE, NBD). Same image, 7 runs per path.
#
# Safety: flock (one runner), per-invocation timeout(1), trap cleanup — avoids
# multi-hour 100% CPU zig openTreeEager on sparse chunk stores.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"
bench_acquire_lock
bench_trap_setup

ROOT="${VOILA_ROOT:-/tmp/voila-e2e-bench}"
IMAGE="${VOILA_IMAGE:-}"
PROBE="${VOILA_PROBE:-etc/os-release}"
RUNS="${VOILA_BENCH_RUNS:-7}"
WARM_SRC="${VOILA_WARM_SOURCE:-/tmp/voila-python313}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ZIG_VOILAD="${ZIG_VOILAD:-$REPO_ROOT/poc/zig-voilad/zig-out/bin/zig-voilad}"
ZIG_FUSE="${ZIG_FUSE:-$REPO_ROOT/poc/zig-fuse/zig-out/bin/zig-fuse}"
GO_BENCH="${GO_BENCH:-$REPO_ROOT/poc/zig-voilad/tools/e2e_mount_bench/e2e_mount_bench}"

if [[ -z "$IMAGE" ]]; then
  echo "set VOILA_IMAGE (e.g. org/python:3.13)" >&2
  exit 2
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 2
fi

drop_caches() {
  sync
  echo 3 > /proc/sys/vm/drop_caches
}

parse_ms() {
  sed -n 's/^rootfs_ready_ms=\([0-9.]*\).*/\1/p'
}

stats() {
  python3 - "$@" <<'PY'
import sys
xs = sorted(float(x) for x in sys.argv[1:])
n = len(xs)
mid = xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2
print(f"{mid:.3f} {xs[0]:.3f} {xs[-1]:.3f}")
PY
}

run_zig() {
  local backend="$1"
  local to="$VOILA_BENCH_TIMEOUT_FUSE"
  if [[ "$backend" == "erofs" ]]; then
    to="$VOILA_BENCH_TIMEOUT_ZIG_EROFS"
  fi
  bench_timeout_run "$to" \
    "$ZIG_VOILAD" bench-once -root "$ROOT" -image "$IMAGE" -backend "$backend" -probe "$PROBE" -zig-fuse "$ZIG_FUSE"
}

run_go() {
  local backend="$1"
  local to="$VOILA_BENCH_TIMEOUT_FUSE"
  if [[ "$backend" == "erofs" ]]; then
    to="$VOILA_BENCH_TIMEOUT_EROFS"
  fi
  bench_timeout_run "$to" \
    "$GO_BENCH" -root "$ROOT" -image "$IMAGE" -backend "$backend" -probe "$PROBE"
}

bench_path() {
  local name="$1"
  local kind="$2"
  local -a times=()
  local i line ms
  for i in $(seq 1 "$RUNS"); do
    bench_cleanup_mounts
    drop_caches
    set +e
    case "$kind" in
      zig-erofs) line="$(run_zig erofs 2>/dev/null)" ;;
      zig-fuse) line="$(run_zig fuse 2>/dev/null)" ;;
      go-fuse) line="$(run_go fuse 2>/dev/null)" ;;
      go-erofs) line="$(run_go erofs 2>/dev/null)" ;;
      *) echo "unknown kind $kind" >&2; exit 1 ;;
    esac
    rc=$?
    set -e
    if [[ $rc -eq 124 ]]; then
      echo "run $i $name TIMEOUT (>${VOILA_BENCH_TIMEOUT_ZIG_EROFS}s)" >&2
      continue
    fi
    ms="$(echo "$line" | parse_ms)"
    if [[ -z "$ms" ]]; then
      echo "run $i $name failed"
    else
      times+=("$ms")
      echo "run $i $name ms=$ms"
    fi
  done
  if [[ ${#times[@]} -eq 0 ]]; then
    echo "$name|n/a|n/a|n/a"
    return
  fi
  read -r med lo hi <<< "$(stats "${times[@]}")"
  echo "$name|$med|$lo|$hi"
}

echo "=== cold chunk fetch (registry chunk cache, capped ${VOILA_BENCH_TIMEOUT_COLD}s) ==="
mkdir -p "$ROOT"
rm -rf "$ROOT/chunks"
mkdir -p "$ROOT/chunks"
ROOT_HEX="${VOILA_ROOT_MANIFEST_HEX:-da16d6f60feefbe5f8c6001b952cff66bd12fd86cb5d0b9e90921177da57d982}"
if [[ -d "$WARM_SRC/chunks/da/16" ]]; then
  mkdir -p "$ROOT/chunks/da/16"
  cp -a "$WARM_SRC/chunks/da/16/$ROOT_HEX" "$ROOT/chunks/da/16/" 2>/dev/null || true
fi
drop_caches
bench_cleanup_mounts
set +e
cold_out="$(bench_timeout_run "$VOILA_BENCH_TIMEOUT_COLD" \
  "$ZIG_VOILAD" bench-once -root "$ROOT" -image "$IMAGE" -backend erofs -probe "$PROBE" -zig-fuse "$ZIG_FUSE" 2>&1)"
cold_rc=$?
set -e
cold_ms="$(echo "$cold_out" | parse_ms)"
chunk_count="$(find "$ROOT/chunks" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ $cold_rc -eq 124 ]]; then
  echo "cold_fetch: TIMEOUT after ${VOILA_BENCH_TIMEOUT_COLD}s (aborted; sync warm chunks next)"
else
  echo "cold_fetch_rootfs_ready_ms=${cold_ms:-FAIL} chunks_on_disk=$chunk_count"
fi
echo "$cold_out" | tail -3

echo "=== warm chunk cache: sync remaining chunks from warm store ==="
if [[ -d "$WARM_SRC/chunks" ]]; then
  rsync -a "$WARM_SRC/chunks/" "$ROOT/chunks/"
fi
chunk_count="$(find "$ROOT/chunks" -type f | wc -l | tr -d ' ')"
echo "chunks_on_disk=$chunk_count"

echo "=== four-way ($RUNS runs each, drop_caches per run) ==="
RESULT_FILE="$(mktemp)"
for p in zig-erofs zig-fuse go-fuse go-erofs; do
  bench_path "$p" "$p" | tee -a "$RESULT_FILE"
done

echo ""
echo "| Path | median ms | min–max ms |"
echo "|------|-----------|------------|"
while IFS='|' read -r name med lo hi; do
  if [[ "$med" == "n/a" ]]; then
    echo "| $name | n/a | n/a |"
  else
    echo "| $name | $med | $lo–$hi |"
  fi
done < "$RESULT_FILE"
rm -f "$RESULT_FILE"
