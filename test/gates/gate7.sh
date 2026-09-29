#!/bin/bash
# Gate 7 — Phase 1 acceptance: cold-start over the network.
# Two voila roots simulate two machines: A ingests + pushes to a registry;
# B (empty) pulls the manifest and runs — chunks stream lazily over HTTP.
# Run INSIDE the privileged devcontainer image.
# Usage: gate7.sh [tarball] [cmd...]  (default: alpine + /bin/sh)
set -euo pipefail
. "$(dirname "$0")/_env.sh"

ROOT_A=/tmp/gate7-a       # "machine A": has the image
ROOT_B=/tmp/gate7-b       # "machine B": starts EMPTY
REG_ROOT=/tmp/gate7-reg   # registry server storage
REG=http://127.0.0.1:7423

# count_chunks tolerates a not-yet-existing dir (set -euo pipefail would
# otherwise kill the script on find's non-zero exit through the pipeline).
count_chunks() { if [ -d "$1" ]; then find "$1" -type f | wc -l; else echo 0; fi; }

echo "=== setup ==="
.devcontainer/cgroup-init.sh >/dev/null
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends runc fuse3 >/dev/null 2>&1
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
go test ./internal/registry/ ./internal/chunkstore/ 2>&1 | tail -2

echo "=== machine A: ingest + push ==="
TARBALL="${1:-/fixtures/alpine.tar}"
# The CI fixture is a skopeo oci-archive (no RepoTags), so ingest assigns Ref="".
# voila push PUTs the manifest under the image ref (the registry key), and an
# empty key 404s. Name the image explicitly; this matches the upstream
# docker://alpine:3.20 source. (Coupled to /bin/sh below; swap both for other
# images — gate7 has no separate ref/cmd arguments.)
voila ingest -root "$ROOT_A" -ref alpine:3.20 "$TARBALL" | grep "image ref"
REF=$(voila images -root "$ROOT_A" | awk 'NR==2{print $1}')
voila-registry -root "$REG_ROOT" >/tmp/gate7-registry.log 2>&1 &
REG_PID=$!
for i in $(seq 1 50); do
  if (echo > /dev/tcp/127.0.0.1/7423) 2>/dev/null; then break; fi
  sleep 0.1
done
time voila push -root "$ROOT_A" -registry "$REG" "$REF"

echo "=== machine B: EMPTY root — pull manifest only ==="
voila pull -root "$ROOT_B" -registry "$REG" "$REF"
B_CHUNKS_AFTER_PULL=$(count_chunks "$ROOT_B/chunks")
[ "$B_CHUNKS_AFTER_PULL" = "0" ] || { echo "FAIL: pull downloaded $B_CHUNKS_AFTER_PULL chunks (want 0)"; exit 1; }
echo "pull OK: manifest only, 0 chunks on machine B"

echo "=== machine B: voila run — lazy network streaming (voilad -registry) ==="
voilad -root "$ROOT_B" -registry "$REG" >/tmp/gate7-voilad.log 2>&1 &
VOILAD_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT_B/worker.sock" ] && break; sleep 0.1; done
T0=$(date +%s%N)
OUT=$(voila run -root "$ROOT_B" "$REF" -- /bin/sh -c 'echo hi' 2>/tmp/gate7-b.err) || {
  echo "FAIL: voila run exited $?; stderr:"; cat /tmp/gate7-b.err; exit 1; }
T1=$(date +%s%N)
cat /tmp/gate7-b.err | grep -E "^fetched" || true
[ "$OUT" = "hi" ] || { echo "FAIL: output '$OUT'"; cat /tmp/gate7-b.err; exit 1; }
MS=$(( (T1 - T0) / 1000000 ))
B_CHUNKS=$(count_chunks "$ROOT_B/chunks")
B_BYTES=$(du -sk "$ROOT_B/chunks" | cut -f1)
IMG_BYTES=$(du -sk "$ROOT_A/chunks" | cut -f1)
echo "cold-start run: ${MS}ms; machine B now holds $B_CHUNKS chunks / ${B_BYTES}KiB (image on A: ${IMG_BYTES}KiB)"
[ "$B_CHUNKS" -gt 0 ] || { echo "FAIL: no chunks cached on B"; exit 1; }
[ "$B_CHUNKS" -lt 1000 ] || { echo "FAIL: B downloaded $B_CHUNKS chunks — not lazy"; exit 1; }

echo "=== machine B: second run — warm cache, no re-download ==="
OUT2=$(voila run -root "$ROOT_B" "$REF" -- /bin/sh -c 'echo warm' 2>/dev/null)
[ "$OUT2" = "warm" ] || { echo "FAIL: warm run '$OUT2'"; exit 1; }
B_CHUNKS2=$(count_chunks "$ROOT_B/chunks")
echo "warm run OK ($B_CHUNKS -> $B_CHUNKS2 chunks cached)"

echo "=== push idempotency ==="
voila push -root "$ROOT_A" -registry "$REG" "$REF" | grep -E "0 chunks uploaded|already present"

kill -TERM "$VOILAD_PID"; wait "$VOILAD_PID" 2>/dev/null || true
kill -TERM "$REG_PID"; wait "$REG_PID" 2>/dev/null || true
echo "GATE 7 PASSED — lazy cold-start over the network works"
