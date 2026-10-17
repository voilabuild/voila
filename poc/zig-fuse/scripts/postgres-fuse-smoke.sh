#!/usr/bin/env bash
# Run PostgreSQL 16-alpine with rootfs on zig-fuse (ro) and PGDATA on tmpfs.
set -euo pipefail

VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-postgres-fuse}"
IMAGE_REF="${IMAGE_REF:-registry-1.docker.io/library/postgres:16-alpine}"
MNT="${MNT:-/tmp/zig-fuse-postgres-mnt}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ZIG_FUSE="$REPO_ROOT/poc/zig-fuse"
ZIG_BIN="${ZIG_BIN:-zig}"
if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "zig not found on PATH (run mise install from the repo root)" >&2
  exit 1
fi
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"

PGDATA_IN_ROOT="/var/lib/postgresql/data"
PG_TMUX="zig-postgres-fuse"
PG_SERVE="pg-fuse"

cleanup() {
  tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_SERVE" 2>/dev/null || true
  sudo pkill -f "postgres -D $PGDATA_IN_ROOT" 2>/dev/null || true
  for mp in "$MNT/dev/shm" "$MNT/var/run/postgresql" "$MNT/tmp" "$MNT/sys" "$MNT/proc" "$MNT/dev" "$MNT$PGDATA_IN_ROOT" "$MNT"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    fi
  done
  tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_TMUX" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$VOILA_ROOT"
if ! "$VOILA_BIN" images -root "$VOILA_ROOT" 2>/dev/null | grep -q postgres; then
  "$VOILA_BIN" import -root "$VOILA_ROOT" docker.io/library/postgres:16-alpine
fi

cd "$ZIG_FUSE"
"$ZIG_BIN" build
ZIG="$ZIG_FUSE/zig-out/bin/zig-fuse"

sudo mkdir -p "$MNT"
tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_TMUX" 2>/dev/null || true
tmux -f /exec-daemon/tmux.portal.conf new-session -d -s "$PG_TMUX" -- "sudo $ZIG serve-store $VOILA_ROOT '$IMAGE_REF' $MNT"
for _ in $(seq 1 80); do
  if sudo test -f "$MNT/etc/os-release"; then break; fi
  sleep 0.25
done
sudo test -f "$MNT/etc/os-release"

sudo mkdir -p "$MNT/var/lib/postgresql" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/tmp" "$MNT/var/run/postgresql"
sudo mount -t tmpfs -o size=512m,uid=70,gid=70 tmpfs "$MNT$PGDATA_IN_ROOT"
sudo mount -t tmpfs -o size=64m,mode=1777 tmpfs "$MNT/tmp"
sudo mount -t tmpfs -o size=16m,uid=70,gid=70 tmpfs "$MNT/var/run/postgresql"
sudo mount --bind /proc "$MNT/proc"
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /sys "$MNT/sys"
sudo mount -t tmpfs -o size=64m tmpfs "$MNT/dev/shm"

if ! sudo chroot "$MNT" /usr/local/bin/su-exec postgres test -x /usr/local/bin/initdb; then
  echo "postgres user cannot execute from FUSE (need allow_other)" >&2
  exit 1
fi

if [ ! -f "$MNT$PGDATA_IN_ROOT/PG_VERSION" ]; then
  sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/initdb \
    -D "$PGDATA_IN_ROOT" -U postgres --auth-host=trust --auth-local=trust
fi

tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_SERVE" 2>/dev/null || true
tmux -f /exec-daemon/tmux.portal.conf new-session -d -s "$PG_SERVE" -- \
  "sudo chroot $MNT /usr/local/bin/su-exec postgres /usr/local/bin/postgres -D $PGDATA_IN_ROOT -c listen_addresses='' -c unix_socket_directories='/var/run/postgresql'"

for _ in $(seq 1 60); do
  if sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
    echo "postgres_fuse_smoke: ok"
    sudo chroot "$MNT" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -c 'SELECT 1'
    exit 0
  fi
  sleep 0.5
done

echo "postgres_fuse_smoke: timed out waiting for SELECT 1" >&2
exit 1
