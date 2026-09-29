#!/bin/bash
# Postgres:16 cold start over the network against an authenticated voila-registry.
# Mirrors gate 6's PG scenario (initdb + server + SQL round trip on RO rootfs,
# PGDATA on tmpfs) but with an EMPTY local root — every chunk streams lazily
# from the registry on first touch. Run INSIDE the privileged devcontainer with
# --network host (or any network that can reach the registry).
#
# Env: REG (registry base, e.g. https://host/registry), VOILA_REGISTRY_TOKEN,
#      REF (image ref to push under, default test/postgres:cold),
#      TARBALL (default /fixtures/postgres16.tar).
set -euo pipefail

REG="${REG:?REG must be set}"
TOK="${VOILA_REGISTRY_TOKEN:?VOILA_REGISTRY_TOKEN must be set}"
REF="${REF:-test/postgres:cold}"
TARBALL="${TARBALL:-/fixtures/postgres16.tar}"
ROOT_A=/tmp/pg-a   # machine A: ingests + pushes
ROOT_B=/tmp/pg-b   # machine B: EMPTY, runs

count_chunks() { if [ -d "$1" ]; then find "$1" -type f | wc -l; else echo 0; fi; }
img_bytes() { if [ -d "$1" ]; then du -sk "$1" | cut -f1; else echo 0; fi; }

echo "=== setup ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad

echo "=== machine A: ingest + push postgres:16 (auth) ==="
rm -rf "$ROOT_A" "$ROOT_B"
time voila ingest -root "$ROOT_A" -ref "$REF" "$TARBALL" | grep "image ref"
IMG_KIB=$(img_bytes "$ROOT_A/chunks")
echo "image on A: ${IMG_KIB}KiB across $(count_chunks "$ROOT_A/chunks") chunks"
time voila push -root "$ROOT_A" -registry "$REG" "$REF"

echo "=== machine B: EMPTY root — pull manifest only (auth) ==="
voila pull -root "$ROOT_B" -registry "$REG" "$REF"
echo "B chunks after pull: $(count_chunks "$ROOT_B/chunks") (want 0)"

echo "=== machine B: cold start — initdb + server + SQL round trip (lazy fetch) ==="
voilad -root "$ROOT_B" -registry "$REG" >/tmp/pg-voilad.log 2>&1 &
VOILAD_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT_B/worker.sock" ] && break; sleep 0.1; done

drop_caches() { echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }

drop_caches
T0=$(date +%s%N)
PGOUT=$(voila run -root "$ROOT_B" "$REF" -- bash -c '
  set -e
  id postgres >/dev/null
  mkdir -p /tmp/pgdata /tmp/pgsock
  chown -R postgres:postgres /tmp/pgdata /tmp/pgsock
  su -s /bin/bash postgres -c "initdb -D /tmp/pgdata" >/dev/null
  su -s /bin/bash postgres -c "pg_ctl -D /tmp/pgdata -o \"-c unix_socket_directories=/tmp/pgsock -c listen_addresses=\" -w -l /tmp/pg.log start" >/dev/null
  su -s /bin/bash postgres -c "psql -h /tmp/pgsock -At -c \"SELECT 40 + 2;\""
  su -s /bin/bash postgres -c "psql -h /tmp/pgsock -At -c \"CREATE TABLE t(v text); INSERT INTO t VALUES ('\''voila'\''); SELECT v FROM t;\"" | tail -1
  su -s /bin/bash postgres -c "pg_ctl -D /tmp/pgdata -m fast -w stop" >/dev/null
' 2>/tmp/pg-run.err)
RC=$?
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))

if [ $RC -ne 0 ]; then echo "FAIL: voila run exited $RC; stderr:"; cat /tmp/pg-run.err; cat /tmp/pg-voilad.log; exit 1; fi
echo "$PGOUT"
echo "$PGOUT" | grep -q '^42$'    || { echo "FAIL: postgres SELECT missing"; cat /tmp/pg-run.err; exit 1; }
echo "$PGOUT" | grep -q '^voila$' || { echo "FAIL: postgres table round-trip missing"; cat /tmp/pg-run.err; exit 1; }

B_CHUNKS=$(count_chunks "$ROOT_B/chunks")
B_KIB=$(img_bytes "$ROOT_B/chunks")
grep -E "^fetched" /tmp/pg-run.err || true
echo "postgres cold-start: ${MS}ms; machine B fetched $B_CHUNKS chunks / ${B_KIB}KiB (image on A: ${IMG_KIB}KiB)"
echo "backend: $(grep 'mount backend' /tmp/pg-voilad.log)"

kill -TERM "$VOILAD_PID"; wait "$VOILAD_PID" 2>/dev/null || true
echo "PG COLD-START PASSED — initdb + server + SQL round trip over the network"
