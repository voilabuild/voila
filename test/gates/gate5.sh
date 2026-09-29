#!/bin/bash
# Gate 5 (plan §11.5), run INSIDE the privileged devcontainer image:
#   docker run --rm --privileged \
#     -v "$PWD:/workspace" -v <tarball-dir>:/fixtures -w /workspace \
#     mcr.microsoft.com/devcontainers/go:1-bookworm bash test/gates/gate5.sh /fixtures/alpine.tar
set -euo pipefail
. "$(dirname "$0")/_env.sh"

TARBALL="${1:?usage: gate5.sh <image-tarball>}"
ROOT=/tmp/gate5-root

echo "=== setup ==="
.devcontainer/cgroup-init.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends runc fuse3 >/dev/null 2>&1

echo "=== unit tests (linux) ==="
CGO_ENABLED=0 go build ./... && go test ./internal/worker/ ./cmd/voila/ 2>&1 | tail -3

echo "=== build + ingest + start daemon ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
voila ingest -root "$ROOT" "$TARBALL" | grep "image ref"
REF=$(voila images -root "$ROOT" | awk 'NR==2{print $1}')
voilad -root "$ROOT" &
WORKER_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT/worker.sock" ] && break; sleep 0.1; done
[ -S "$ROOT/worker.sock" ] || { echo "FAIL: worker socket never appeared"; exit 1; }

echo "=== 1. run via daemon (stdout + exit code) ==="
OUT=$(voila run -root "$ROOT" "$REF" -- /bin/sh -c 'echo via-daemon' 2>/dev/null)
[ "$OUT" = "via-daemon" ] || { echo "FAIL: got '$OUT'"; exit 1; }
set +e; voila run -root "$ROOT" "$REF" -- /bin/sh -c 'exit 9' 2>/dev/null; RC=$?; set -e
[ "$RC" = "9" ] || { echo "FAIL: exit $RC want 9"; exit 1; }
echo "run-via-daemon OK"

echo "=== 2. long-running ctx + exec + logs + ps ==="
voila run -root "$ROOT" "$REF" -- /bin/sh -c 'echo started; sleep 30' >/tmp/gate5-run.out 2>/tmp/gate5-run.err &
RUN_PID=$!
CTX=""
for i in $(seq 1 100); do
  CTX=$(voila ps -root "$ROOT" 2>/dev/null | awk 'NR>1 && $3=="running" {print $1; exit}')
  [ -n "$CTX" ] && break; sleep 0.1
done
[ -n "$CTX" ] || { echo "FAIL: no running context in ps"; voila ps -root "$ROOT"; exit 1; }
echo "running ctx: $CTX"

EXEC_OUT=$(voila exec -root "$ROOT" "$CTX" -- /bin/sh -c 'echo from-exec')
[ "$EXEC_OUT" = "from-exec" ] || { echo "FAIL: exec got '$EXEC_OUT'"; exit 1; }
echo "exec OK"

LOGS=$(voila logs -root "$ROOT" "$CTX")
echo "$LOGS" | grep -q '^started$' || { echo "FAIL: logs missing 'started': $LOGS"; exit 1; }
echo "$LOGS" | grep -q 'from-exec' && { echo "FAIL: exec output leaked into logs"; exit 1; }
echo "logs replay OK (and exec output correctly absent)"

echo "=== 3. detach semantics: kill the CLI, ctx keeps running ==="
kill -9 "$RUN_PID" 2>/dev/null || true; sleep 0.5
STATUS=$(voila ps -root "$ROOT" | awk -v c="$CTX" '$1==c {print $3}')
[ "$STATUS" = "running" ] || { echo "FAIL: ctx status after client kill: $STATUS"; exit 1; }
echo "detach OK"

echo "=== 4. kill ctx, status finished ==="
# SIGKILL: the ctx init is `sh -c`, and a pid-namespace init IGNORES SIGTERM
# unless it installs a handler (standard kernel semantics; docker kill behaves
# identically). SIGKILL bypasses that and proves the kill plumbing end to end.
voila kill -root "$ROOT" -signal 9 "$CTX"
for i in $(seq 1 50); do
  STATUS=$(voila ps -root "$ROOT" | awk -v c="$CTX" '$1==c {print $3}')
  [ "$STATUS" = "finished" ] && break; sleep 0.1
done
[ "$STATUS" = "finished" ] || { echo "FAIL: status $STATUS after kill"; exit 1; }
echo "kill OK"

echo "=== 5. images info / rm / gc ==="
voila images info -root "$ROOT" "$REF" | head -4
kill -TERM "$WORKER_PID"; wait "$WORKER_PID" 2>/dev/null || true   # gc requires stopped worker
CHUNKS_BEFORE=$(find "$ROOT/chunks" -type f | wc -l)
voila images gc -root "$ROOT"   # nothing unreachable yet
CHUNKS_MID=$(find "$ROOT/chunks" -type f | wc -l)
[ "$CHUNKS_BEFORE" = "$CHUNKS_MID" ] || { echo "FAIL: gc removed reachable chunks ($CHUNKS_BEFORE -> $CHUNKS_MID)"; exit 1; }
voila images rm -root "$ROOT" "$REF"
voila images gc -root "$ROOT"
CHUNKS_AFTER=$(find "$ROOT/chunks" -type f | wc -l)
[ "$CHUNKS_AFTER" = "0" ] || { echo "FAIL: $CHUNKS_AFTER chunks left after rm+gc"; exit 1; }
echo "images info/rm/gc OK ($CHUNKS_BEFORE chunks -> 0)"

echo "GATE 5 PASSED"
