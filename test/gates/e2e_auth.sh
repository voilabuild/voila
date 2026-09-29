#!/bin/bash
# E2E auth flow against the running voila-registry (cloud registry with
# Bearer API key auth) on the host. Run INSIDE the privileged devcontainer
# with --network host so localhost:7423 (registry) + localhost:9000 (MinIO
# chunk origin) resolve to the host.
set -euo pipefail

REG="${REG:-http://localhost:7423/registry}"
TOK="${VOILA_REGISTRY_TOKEN:?VOILA_REGISTRY_TOKEN must be set}"
REF="${REF:-test/testrepo:latest}"

ROOT_A=/tmp/e2e-a   # "machine A": has the image
ROOT_B=/tmp/e2e-b   # "machine B": starts EMPTY

count_chunks() { if [ -d "$1" ]; then find "$1" -type f | wc -l; else echo 0; fi; }

echo "=== setup ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry

echo "=== auth sanity: no token -> 401, with token -> 200 ==="
NO_AUTH=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"ids":[]}' "$REG/v1/chunks/missing")
WITH_AUTH=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{"ids":[]}' "$REG/v1/chunks/missing")
echo "missing(no auth)=$NO_AUTH  missing(auth)=$WITH_AUTH"
[ "$NO_AUTH" = "401" ] || { echo "FAIL: expected 401 without token, got $NO_AUTH"; exit 1; }
[ "$WITH_AUTH" = "200" ] || { echo "FAIL: expected 200 with token, got $WITH_AUTH"; exit 1; }

echo "=== machine A: ingest + push (auth) ==="
rm -rf "$ROOT_A" "$ROOT_B"
voila ingest -root "$ROOT_A" -ref "$REF" /fixtures/alpine.tar | grep "image ref"
echo "pushing $REF ..."
time voila push -root "$ROOT_A" -registry "$REG" "$REF"

echo "=== machine B: EMPTY root — pull manifest only (auth) ==="
voila pull -root "$ROOT_B" -registry "$REG" "$REF"
B_AFTER_PULL=$(count_chunks "$ROOT_B/chunks")
[ "$B_AFTER_PULL" = "0" ] || { echo "FAIL: pull downloaded $B_AFTER_PULL chunks (want 0)"; exit 1; }
echo "pull OK: manifest only, 0 chunks on machine B"

echo "=== machine B: voila run — lazy network streaming (auth) ==="
voilad -root "$ROOT_B" -registry "$REG" >/tmp/e2e-voilad.log 2>&1 &
VOILAD_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT_B/worker.sock" ] && break; sleep 0.1; done
T0=$(date +%s%N)
OUT=$(voila run -root "$ROOT_B" "$REF" -- /bin/sh -c 'echo hi' 2>/tmp/e2e-b.err) || {
  echo "FAIL: voila run exited $?; stderr:"; cat /tmp/e2e-b.err; exit 1; }
T1=$(date +%s%N)
grep -E "^fetched" /tmp/e2e-b.err || true
[ "$OUT" = "hi" ] || { echo "FAIL: output '$OUT'"; cat /tmp/e2e-b.err; exit 1; }
MS=$(( (T1 - T0) / 1000000 ))
B_CHUNKS=$(count_chunks "$ROOT_B/chunks")
echo "cold-start run: ${MS}ms; machine B now holds $B_CHUNKS chunks"
[ "$B_CHUNKS" -gt 0 ] || { echo "FAIL: no chunks cached on B"; exit 1; }

echo "=== machine B: second run — warm cache, no re-download ==="
OUT2=$(voila run -root "$ROOT_B" "$REF" -- /bin/sh -c 'echo warm' 2>/dev/null)
[ "$OUT2" = "warm" ] || { echo "FAIL: warm run '$OUT2'"; exit 1; }
B_CHUNKS2=$(count_chunks "$ROOT_B/chunks")
echo "warm run OK ($B_CHUNKS -> $B_CHUNKS2 chunks cached)"
[ "$B_CHUNKS2" = "$B_CHUNKS" ] || { echo "FAIL: warm run changed chunk count (re-download?)"; exit 1; }

echo "=== push idempotency (auth) ==="
voila push -root "$ROOT_A" -registry "$REG" "$REF" | grep -E "0 chunks uploaded|already present"

kill -TERM "$VOILAD_PID"; wait "$VOILAD_PID" 2>/dev/null || true
echo "E2E AUTH PASSED — full flow (ingest+push+pull+run) works against authenticated registry"
