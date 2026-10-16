#!/usr/bin/env bash
# PostgreSQL smoke via voilad mount (zig-fuse when available), not direct zig-fuse.
set -euo pipefail

VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-postgres-fuse}"
IMAGE_REF="${IMAGE_REF:-registry-1.docker.io/library/postgres:16-alpine}"
MNT="${MNT:-/tmp/voilad-zig-postgres-mnt}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"
VOILAD_BIN="${VOILAD_BIN:-/tmp/voilad}"
ZIG_FUSE="${ZIG_FUSE:-$REPO_ROOT/poc/zig-fuse/zig-out/bin/zig-fuse}"

PGDATA_IN_ROOT="/var/lib/postgresql/data"
VOILAD_PID=""

cleanup() {
  sudo pkill -f "postgres -D $PGDATA_IN_ROOT" 2>/dev/null || true
  if [ -n "$VOILAD_PID" ] && kill -0 "$VOILAD_PID" 2>/dev/null; then
    kill -TERM "$VOILAD_PID" 2>/dev/null || true
    wait "$VOILAD_PID" 2>/dev/null || true
  fi
  for mp in "$MNT/dev/shm" "$MNT/var/run/postgresql" "$MNT/tmp" "$MNT/sys" "$MNT/proc" "$MNT/dev" "$MNT$PGDATA_IN_ROOT" "$MNT"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

mkdir -p "$VOILA_ROOT"
if ! "$VOILA_BIN" images -root "$VOILA_ROOT" 2>/dev/null | grep -qi postgres; then
  "$VOILA_BIN" import -root "$VOILA_ROOT" docker.io/library/postgres:16-alpine
fi

export VOILA_ZIG_FUSE="$ZIG_FUSE"
export VOILA_MOUNT_FUSE="${VOILA_MOUNT_FUSE:-auto}"

sudo mkdir -p "$MNT"
sudo -E env VOILA_ZIG_FUSE="$ZIG_FUSE" VOILA_MOUNT_FUSE="$VOILA_MOUNT_FUSE" \
  "$VOILAD_BIN" mount -root "$VOILA_ROOT" -allow-other "$IMAGE_REF" "$MNT" >/tmp/voilad-mount-smoke.log 2>&1 &
VOILAD_PID=$!

for _ in $(seq 1 80); do
  if sudo test -f "$MNT/etc/os-release"; then break; fi
  sleep 0.25
done
sudo test -f "$MNT/etc/os-release"
grep -q 'zig-fuse' /tmp/voilad-mount-smoke.log || { cat /tmp/voilad-mount-smoke.log; exit 1; }

sudo mkdir -p "$MNT/var/lib/postgresql" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/var/run/postgresql"
sudo mount -t tmpfs -o size=512m,uid=70,gid=70 tmpfs "$MNT$PGDATA_IN_ROOT"
sudo mount -t tmpfs -o size=64m,mode=1777 tmpfs "$MNT/tmp"
sudo mount -t tmpfs -o size=16m,uid=70,gid=70 tmpfs "$MNT/var/run/postgresql"
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /sys "$MNT/sys"
sudo mount -t tmpfs -o size=64m tmpfs "$MNT/dev/shm"

sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/initdb \
  -D "$PGDATA_IN_ROOT" -U postgres --auth-host=trust --auth-local=trust >/dev/null 2>&1 || true

if [ ! -f "$MNT$PGDATA_IN_ROOT/PG_VERSION" ]; then
  sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/initdb \
    -D "$PGDATA_IN_ROOT" -U postgres --auth-host=trust --auth-local=trust
fi

sudo chroot "$MNT" /usr/local/bin/su-exec postgres sh -c \
  "/usr/local/bin/postgres -D $PGDATA_IN_ROOT -c listen_addresses='' -c unix_socket_directories='/var/run/postgresql' >>/tmp/pg.log 2>&1" &
for _ in $(seq 1 60); do
  if sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
    echo "voilad_mount_postgres_smoke: ok"
    sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -c 'SELECT 1'
    echo "--- voilad mount log ---"
    cat /tmp/voilad-mount-smoke.log
    exit 0
  fi
  sleep 0.5
done
echo "timeout" >&2
cat /tmp/voilad-mount-smoke.log >&2
exit 1
