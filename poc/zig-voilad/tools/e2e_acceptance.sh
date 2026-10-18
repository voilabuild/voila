#!/usr/bin/env bash
# Repeatable four-backend acceptance suite (python:3.13 warm store).
# Order: zig-erofs, zig-fuse, go-erofs, go-fuse. Requires root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bench_common.sh
source "$SCRIPT_DIR/bench_common.sh"
bench_acquire_lock
bench_trap_setup

ROOT="${VOILA_ROOT:-/tmp/voila-python313}"
IMAGE="${VOILA_IMAGE:-registry-1.docker.io/library/python:3.13}"
GOLDEN="${VOILA_ACCEPT_GOLDEN:-/tmp/voila-accept-golden}"
CASES="${VOILA_ACCEPT_CASES:-$SCRIPT_DIR/acceptance_cases.sh}"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ZIG_VOILAD="${ZIG_VOILAD:-$REPO_ROOT/poc/zig-voilad/zig-out/bin/zig-voilad}"
ZIG_FUSE="${ZIG_FUSE:-$REPO_ROOT/poc/zig-fuse/zig-out/bin/zig-fuse}"
GO_ACCEPT="${GO_ACCEPT:-$REPO_ROOT/poc/zig-voilad/tools/e2e_acceptance/e2e_acceptance}"
: "${VOILA_BENCH_TIMEOUT_ZIG_EROFS:=180}"
: "${VOILA_BENCH_TIMEOUT_FUSE:=120}"
: "${VOILA_BENCH_TIMEOUT_EROFS:=180}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 2
fi

if [[ ! -x "$CASES" ]]; then
  chmod +x "$CASES"
fi

rm -rf "$GOLDEN"
mkdir -p "$GOLDEN"

declare -A RESULT
HELLO_ZIG_EROFS="n/a"

run_zig() {
  local backend="$1"
  local to="$VOILA_BENCH_TIMEOUT_FUSE"
  [[ "$backend" == "erofs" ]] && to="$VOILA_BENCH_TIMEOUT_ZIG_EROFS"
  bench_cleanup_mounts
  bench_timeout_run "$to" \
    "$ZIG_VOILAD" accept-suite \
    -root "$ROOT" \
    -image "$IMAGE" \
    -backend "$backend" \
    -zig-fuse "$ZIG_FUSE" \
    -cases-script "$CASES" \
    -golden "$GOLDEN"
}

run_go() {
  local backend="$1"
  local to="$VOILA_BENCH_TIMEOUT_FUSE"
  [[ "$backend" == "erofs" ]] && to="$VOILA_BENCH_TIMEOUT_EROFS"
  bench_cleanup_mounts
  bench_timeout_run "$to" \
    "$GO_ACCEPT" \
    -root "$ROOT" \
    -image "$IMAGE" \
    -backend "$backend" \
    -cases-script "$CASES" \
    -golden "$GOLDEN"
}

record_output() {
  local backend="$1"
  local log="$2"
  local rc="$3"
  if [[ "$rc" -eq 124 ]]; then
    for c in hello symlink nested multichunk permissions; do
      RESULT["${backend}:${c}"]="TIMEOUT"
    done
    return
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ accept_case=([^[:space:]]+)[[:space:]]pass=([01]) ]]; then
      RESULT["${backend}:${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
    if [[ "$backend" == "zig-erofs" && "$line" =~ hello_wall_ms=([0-9.]+) ]]; then
      HELLO_ZIG_EROFS="${BASH_REMATCH[1]}"
    fi
  done <"$log"
  for c in hello symlink nested multichunk permissions; do
    [[ -n "${RESULT[${backend}:${c}]:-}" ]] || RESULT["${backend}:${c}"]="FAIL"
  done
}

run_backend() {
  local label="$1"
  local kind="$2"
  local log
  log="$(mktemp)"
  echo "=== ${label} ===" >&2
  set +e
  case "$kind" in
    zig-erofs) run_zig erofs >"$log" 2>&1 ;;
    zig-fuse) run_zig fuse >"$log" 2>&1 ;;
    go-erofs) run_go erofs >"$log" 2>&1 ;;
    go-fuse) run_go fuse >"$log" 2>&1 ;;
    *) echo "unknown $kind" >&2; exit 1 ;;
  esac
  local rc=$?
  set -e
  cat "$log" >&2
  record_output "$label" "$log" "$rc"
  rm -f "$log"
  bench_cleanup_mounts
}

BACKENDS=(zig-erofs zig-fuse go-erofs go-fuse)
for b in "${BACKENDS[@]}"; do
  run_backend "$b" "$b"
done

bench_cleanup_mounts

echo ""
echo "## Acceptance results (${IMAGE}, store=${ROOT})"
echo ""
echo "| Backend | hello | symlink | nested | multichunk | permissions |"
echo "|---------|-------|---------|--------|------------|-------------|"
for b in "${BACKENDS[@]}"; do
  printf '| %s |' "$b"
  for c in hello symlink nested multichunk permissions; do
    v="${RESULT[${b}:${c}]:-?}"
    if [[ "$v" == "1" ]]; then
      printf ' pass |'
    elif [[ "$v" == "0" || "$v" == "FAIL" ]]; then
      printf ' **FAIL** |'
    elif [[ "$v" == "TIMEOUT" ]]; then
      printf ' TIMEOUT |'
    else
      printf ' %s |' "$v"
    fi
  done
  echo ""
done
echo ""
echo "Zig EROFS hello_world_wall_s=${HELLO_ZIG_EROFS}s"
echo ""

FAIL=0
for b in "${BACKENDS[@]}"; do
  for c in hello symlink nested multichunk permissions; do
    [[ "${RESULT[${b}:${c}]:-}" == "1" ]] || FAIL=1
  done
done
exit "$FAIL"
