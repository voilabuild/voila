#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-zig-lifecycle}"
SOCKET="${SOCKET:-$VOILA_ROOT/worker.sock}"
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"
ZIG_VOILAD="${ZIG_VOILAD:-$ROOT/zig-out/bin/zig-voilad}"
ZIG_FUSE="${ZIG_FUSE:-$ROOT/../zig-fuse/zig-out/bin/zig-fuse}"
DOC_OUT="${DOC_OUT:-/cursor/stores/self/docs/zig-voilad-lifecycle.md}"

mkdir -p "$(dirname "$DOC_OUT")"
RESULTS=()

record() {
  RESULTS+=("$1: $2")
}

run_cmd() {
  echo "\`\`\`"
  echo "$*"
  echo "\`\`\`"
  echo '```'
  "$@" 2>&1 || true
  echo '```'
  echo
}

sudo rm -rf "$VOILA_ROOT" 2>/dev/null || true
mkdir -p "$VOILA_ROOT"
rm -f "$SOCKET"

{
  echo "# zig-voilad lifecycle proof"
  echo
  echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Setup"
  run_cmd "$VOILA_BIN" import docker.io/library/alpine:latest -root "$VOILA_ROOT"
} >"$DOC_OUT"

sudo "$ZIG_VOILAD" -root "$VOILA_ROOT" -socket "$SOCKET" -zig-fuse "$ZIG_FUSE" &
DAEMON_PID=$!
sleep 2

cleanup() {
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Events: subscribe before Run (no replay — must not miss SCHEDULED).
EVENTS_LOG="$(mktemp)"
export VOILA_SOCKET="$SOCKET"
export EVENTS_TIMEOUT=90s
(
  cd "$REPO_ROOT"
  go run ./poc/zig-voilad/scripts/events_subscriber.go
) >"$EVENTS_LOG" 2>&1 &
EVENTS_PID=$!
sleep 1

RUN_OUT="$(mktemp)"
if "$VOILA_BIN" run -root "$VOILA_ROOT" -socket "$SOCKET" alpine:latest -- /bin/sh -c 'echo hello-logs; sleep 600' >"$RUN_OUT" 2>&1 &
then
  RUN_PID=$!
  sleep 6
  if grep -q hello-logs "$RUN_OUT" 2>/dev/null; then
    record Run pass
  else
    record Run fail
  fi
else
  record Run fail
  RUN_PID=""
fi

CTX_ID=$("$VOILA_BIN" ps -root "$VOILA_ROOT" -socket "$SOCKET" 2>/dev/null | awk '/voila-/{print $1; exit}')
echo "CTX_ID=$CTX_ID" >>"$DOC_OUT"

{
  echo "## List (voila ps)"
  if "$VOILA_BIN" ps -root "$VOILA_ROOT" -socket "$SOCKET" | grep -q "$CTX_ID"; then
    record List pass
  else
    record List fail
  fi
  run_cmd "$VOILA_BIN" ps -root "$VOILA_ROOT" -socket "$SOCKET"
  echo "## Logs"
  if "$VOILA_BIN" logs -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID" 2>/dev/null | grep -q hello-logs; then
    record Logs pass
  else
    record Logs fail
  fi
  run_cmd "$VOILA_BIN" logs -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID"
  echo "## Exec"
  if "$VOILA_BIN" exec -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID" -- /bin/echo exec-ok 2>/dev/null | grep -q exec-ok; then
    record Exec pass
  else
    record Exec fail
  fi
  run_cmd "$VOILA_BIN" exec -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID" -- /bin/echo exec-ok
  echo "## Kill"
  if "$VOILA_BIN" kill -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID" 2>/dev/null; then
    record Kill pass
  else
    record Kill fail
  fi
  run_cmd "$VOILA_BIN" kill -root "$VOILA_ROOT" -socket "$SOCKET" "$CTX_ID"
} >>"$DOC_OUT"

if [[ -n "${RUN_PID:-}" ]]; then
  wait "$RUN_PID" 2>/dev/null || true
fi
wait "$EVENTS_PID" 2>/dev/null || true

{
  echo "## Events (subscriber before Run)"
  echo '```'
  cat "$EVENTS_LOG" || true
  echo '```'
  echo
} >>"$DOC_OUT"

if grep -q events-ok "$EVENTS_LOG" 2>/dev/null; then
  record Events pass
else
  record Events fail
fi

{
  echo "## Results"
  for r in "${RESULTS[@]}"; do
    echo "- $r"
  done
  echo
  echo "Merge with PR #9 (cursor/zig-voilad-registry): yes — test-merged locally; lifecycle RPCs + SetRegistry + per-call threading."
} >>"$DOC_OUT"

echo "Wrote $DOC_OUT"
for r in "${RESULTS[@]}"; do echo "$r"; done
