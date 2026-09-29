#!/bin/bash
# Gate 6 — the v0.1 acceptance bar (plan §11.6) + a real-database scenario.
# Run INSIDE the privileged devcontainer image:
#   docker run --rm --privileged \
#     -v "$PWD:/workspace" -v <tarball-dir>:/fixtures -w /workspace \
#     mcr.microsoft.com/devcontainers/go:1-bookworm bash test/gates/gate6.sh
# Expects /fixtures/python313.tar and /fixtures/postgres16.tar (docker save output).
set -euo pipefail
. "$(dirname "$0")/_env.sh"

ROOT=/tmp/gate6-root

echo "=== setup ==="
.devcontainer/cgroup-init.sh
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends runc fuse3 >/dev/null 2>&1
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
go test ./internal/runtime/ 2>&1 | tail -1

echo "=== acceptance §11.6: python:3.13 ==="
time voila ingest -root "$ROOT" /fixtures/python313.tar
PYREF=$(voila images -root "$ROOT" | awk '/python/{print $1}')

voilad -root "$ROOT" &
WORKER_PID=$!
for i in $(seq 1 50); do [ -S "$ROOT/worker.sock" ] && break; sleep 0.1; done

# The formal bar: single command after conversion; stdout via the framed
# (gRPC) I/O path; sub-second wall clock to first byte.
T0=$(date +%s%N)
OUT=$(voila run -root "$ROOT" "$PYREF" -- python -c 'print("hi")' 2>/dev/null)
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
[ "$OUT" = "hi" ] || { echo "FAIL: python output '$OUT'"; exit 1; }
echo "python acceptance OK: 'hi' via daemon in ${MS}ms (bar: <1000ms)"
[ "$MS" -lt 1000 ] || { echo "FAIL: wall clock ${MS}ms exceeds 1s bar"; exit 1; }

# A second, non-trivial python check through the lazy FS (imports touch many files).
OUT2=$(voila run -root "$ROOT" "$PYREF" -- python -c 'import json,hashlib,sqlite3; print(json.dumps({"ok": True}))' 2>/dev/null)
[ "$OUT2" = '{"ok": true}' ] || { echo "FAIL: python stdlib check '$OUT2'"; exit 1; }
echo "python stdlib-import check OK"

echo "=== postgres:16 — real database on tmpfs PGDATA ==="
time voila ingest -root "$ROOT" /fixtures/postgres16.tar
PGREF=$(voila images -root "$ROOT" | awk '/postgres/{print $1}')

# Exercises: multi-layer debian ingest, uid/gid preservation (postgres user),
# setuid su (docker-default caps), lazy FUSE serving, tmpfs writes, a real
# initdb + server + SQL round trip. PGDATA + socket live on tmpfs (/tmp);
# rootfs stays read-only.
PGOUT=$(voila run -root "$ROOT" "$PGREF" -- bash -c '
  set -e
  id postgres >/dev/null                            # uid/gid metadata survived ingest
  mkdir -p /tmp/pgdata /tmp/pgsock
  chown -R postgres:postgres /tmp/pgdata /tmp/pgsock
  su -s /bin/bash postgres -c "initdb -D /tmp/pgdata" >/dev/null
  su -s /bin/bash postgres -c "pg_ctl -D /tmp/pgdata -o \"-c unix_socket_directories=/tmp/pgsock -c listen_addresses=\" -w -l /tmp/pg.log start" >/dev/null
  su -s /bin/bash postgres -c "psql -h /tmp/pgsock -At -c \"SELECT 40 + 2;\""
  su -s /bin/bash postgres -c "psql -h /tmp/pgsock -At -c \"CREATE TABLE t(v text); INSERT INTO t VALUES ('\''voila'\''); SELECT v FROM t;\"" | tail -1
  su -s /bin/bash postgres -c "pg_ctl -D /tmp/pgdata -m fast -w stop" >/dev/null
' 2>/dev/null)
echo "$PGOUT"
echo "$PGOUT" | grep -q '^42$'    || { echo "FAIL: postgres SELECT missing"; exit 1; }
echo "$PGOUT" | grep -q '^voila$' || { echo "FAIL: postgres table round-trip missing"; exit 1; }
echo "postgres OK: initdb + server + SQL round trip on RO rootfs (PGDATA on tmpfs)"

echo "=== teardown ==="
kill -TERM "$WORKER_PID"; wait "$WORKER_PID" 2>/dev/null || true
if mount | grep -q voilafs; then echo "FAIL: leftover voilafs mounts"; exit 1; fi
echo "GATE 6 PASSED — v0.1 acceptance complete"
