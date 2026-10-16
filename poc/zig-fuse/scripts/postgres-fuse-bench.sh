#!/usr/bin/env bash
# Benchmark PostgreSQL 16-alpine on Zig FUSE vs Go (voilad) FUSE rootfs.
# Cold: drop_caches, fresh mount process, empty PGDATA on tmpfs (3 runs, median).
# Phases: rootfs_ready, initdb, postgres_ready, select1_cold; warm = second SELECT 1.
set -euo pipefail

BACKEND="${1:-all}" # zig | go | all
RUNS="${RUNS:-3}"
VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-postgres-fuse}"
IMAGE_REF="${IMAGE_REF:-registry-1.docker.io/library/postgres:16-alpine}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ZIG_FUSE="$REPO_ROOT/poc/zig-fuse"
ZIG_BIN="${ZIG_BIN:-zig}"
if ! command -v "$ZIG_BIN" >/dev/null 2>&1 && [ -x /tmp/zig-x86_64-linux-0.17.0/zig ]; then
  ZIG_BIN=/tmp/zig-x86_64-linux-0.17.0/zig
fi
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"
VOILAD_BIN="${VOILAD_BIN:-/tmp/voilad}"

PGDATA_IN_ROOT="/var/lib/postgresql/data"
MNT_ZIG="${MNT_ZIG:-/tmp/zig-fuse-postgres-mnt}"
MNT_GO="${MNT_GO:-/tmp/go-fuse-postgres-mnt}"

now_ns() { date +%s%N; }
drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }

MOUNT_PID=""
MOUNT_TMUX=""
PG_TMUX=""

stop_postgres() {
  sudo pkill -f "postgres -D $PGDATA_IN_ROOT" 2>/dev/null || true
  sleep 0.2
}

cleanup_mount() {
  stop_postgres
  tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_TMUX" 2>/dev/null || true
  if [ -n "$MOUNT_PID" ] && kill -0 "$MOUNT_PID" 2>/dev/null; then
    kill -TERM "$MOUNT_PID" 2>/dev/null || true
    wait "$MOUNT_PID" 2>/dev/null || true
  fi
  MOUNT_PID=""
  for mnt in "$1"; do
    for mp in "$mnt/dev/shm" "$mnt/var/run/postgresql" "$mnt/tmp" "$mnt/sys" "$mnt/proc" "$mnt/dev" "$mnt$PGDATA_IN_ROOT" "$mnt"; do
      if mountpoint -q "$mp" 2>/dev/null; then
        sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
      fi
    done
    if mountpoint -q "$mnt" 2>/dev/null; then
      sudo fusermount3 -u "$mnt" 2>/dev/null || sudo umount "$mnt" 2>/dev/null || true
    fi
  done
}

setup_chroot_mounts() {
  local mnt="$1"
  sudo mkdir -p "$mnt/var/lib/postgresql" "$mnt/dev" "$mnt/proc" "$mnt/sys" "$mnt/tmp" "$mnt/var/run/postgresql"
  sudo mount -t tmpfs -o size=512m,uid=70,gid=70 tmpfs "$mnt$PGDATA_IN_ROOT"
  sudo mount -t tmpfs -o size=64m,mode=1777 tmpfs "$mnt/tmp"
  sudo mount -t tmpfs -o size=16m,uid=70,gid=70 tmpfs "$mnt/var/run/postgresql"
  sudo mount --bind /proc "$mnt/proc"
  sudo mount --bind /dev "$mnt/dev"
  sudo mount --bind /sys "$mnt/sys"
  sudo mount -t tmpfs -o size=64m tmpfs "$mnt/dev/shm"
}

start_zig_mount() {
  local mnt="$1"
  local zig="$ZIG_FUSE/zig-out/bin/zig-fuse"
  MOUNT_TMUX="zig-pg-bench"
  tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$MOUNT_TMUX" 2>/dev/null || true
  local t0
  t0=$(now_ns)
  tmux -f /exec-daemon/tmux.portal.conf new-session -d -s "$MOUNT_TMUX" -- \
    "sudo $zig serve-store $VOILA_ROOT '$IMAGE_REF' $mnt"
  for _ in $(seq 1 120); do
    if sudo test -f "$mnt/etc/os-release" 2>/dev/null; then
      echo "$(( $(now_ns) - t0 ))"
      return 0
    fi
    sleep 0.1
  done
  echo "mount timeout" >&2
  return 1
}

start_go_mount() {
  local mnt="$1"
  sudo mkdir -p "$mnt"
  local t0
  t0=$(now_ns)
  sudo "$VOILAD_BIN" mount -root "$VOILA_ROOT" -allow-other "$IMAGE_REF" "$mnt" >/tmp/voilad-pg-bench.log 2>&1 &
  MOUNT_PID=$!
  for _ in $(seq 1 120); do
    if sudo test -f "$mnt/etc/os-release" 2>/dev/null; then
      echo "$(( $(now_ns) - t0 ))"
      return 0
    fi
    sleep 0.1
  done
  echo "go mount timeout; log:" >&2
  cat /tmp/voilad-pg-bench.log >&2 || true
  return 1
}

run_one_cold() {
  local backend="$1" # zig | go
  local mnt label
  if [ "$backend" = zig ]; then
    mnt="$MNT_ZIG"
    label="Zig FUSE"
  else
    mnt="$MNT_GO"
    label="Go FUSE (voilad mount)"
  fi

  drop_caches
  cleanup_mount "$mnt"

  local rootfs_ns initdb_ns pg_ready_ns select1_ns select1_warm_ns
  if [ "$backend" = zig ]; then
    rootfs_ns=$(start_zig_mount "$mnt")
  else
    rootfs_ns=$(start_go_mount "$mnt")
  fi

  setup_chroot_mounts "$mnt"

  if ! sudo chroot "$mnt" /usr/local/bin/su-exec postgres test -x /usr/local/bin/initdb; then
    echo "$label: cannot exec initdb from mount" >&2
    return 1
  fi

  local t_init
  t_init=$(now_ns)
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/initdb \
    -D "$PGDATA_IN_ROOT" -U postgres --auth-host=trust --auth-local=trust >/dev/null
  initdb_ns=$(( $(now_ns) - t_init ))

  PG_TMUX="pg-bench-$$"
  tmux -f /exec-daemon/tmux.portal.conf kill-session -t "$PG_TMUX" 2>/dev/null || true
  local t_pg
  t_pg=$(now_ns)
  tmux -f /exec-daemon/tmux.portal.conf new-session -d -s "$PG_TMUX" -- \
    "sudo chroot $mnt /usr/local/bin/su-exec postgres /usr/local/bin/postgres -D $PGDATA_IN_ROOT -c listen_addresses='' -c unix_socket_directories='/var/run/postgresql'"

  pg_ready_ns=0
  for _ in $(seq 1 120); do
    if sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1' 2>/dev/null | grep -q 1; then
      pg_ready_ns=$(( $(now_ns) - t_pg ))
      break
    fi
    sleep 0.1
  done
  if [ "$pg_ready_ns" -eq 0 ]; then
    echo "$label: postgres ready timeout" >&2
    cleanup_mount "$mnt"
    return 1
  fi

  local t_sel
  t_sel=$(now_ns)
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1' >/dev/null
  select1_ns=$(( $(now_ns) - t_sel ))

  t_sel=$(now_ns)
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1' >/dev/null
  select1_warm_ns=$(( $(now_ns) - t_sel ))

  cleanup_mount "$mnt"

  # Output: backend rootfs initdb pg_ready select1_cold select1_warm (nanoseconds)
  echo "$backend $rootfs_ns $initdb_ns $pg_ready_ns $select1_ns $select1_warm_ns"
}

median_ns() {
  # shellcheck disable=SC2207
  local sorted=( $(printf '%s\n' "$@" | sort -n) )
  local n=${#sorted[@]}
  if [ "$(( n % 2 ))" -eq 1 ]; then
    echo "${sorted[$(( n / 2 ))]}"
  else
    echo $(( ( sorted[$(( n / 2 - 1 ))] + sorted[$(( n / 2 ))] ) / 2 ))
  fi
}

fmt_ms() {
  awk -v ns="$1" 'BEGIN { printf "%.2f", ns / 1e6 }'
}

ensure_image() {
  mkdir -p "$VOILA_ROOT"
  if ! "$VOILA_BIN" images -root "$VOILA_ROOT" 2>/dev/null | grep -qi postgres; then
    echo "Importing $IMAGE_REF ..."
    "$VOILA_BIN" import -root "$VOILA_ROOT" docker.io/library/postgres:16-alpine
  fi
}

build_zig() {
  cd "$ZIG_FUSE"
  if [ ! -x "$ZIG_FUSE/zig-out/bin/zig-fuse" ]; then
    "$ZIG_BIN" build
  fi
}

run_backend() {
  local backend="$1"
  local -a r_root r_init r_pg r_sel r_warm
  local i line
  for i in $(seq 1 "$RUNS"); do
    echo "=== cold run $i/$RUNS ($backend) ===" >&2
    line=$(run_one_cold "$backend")
    read -r _ r_root[i] r_init[i] r_pg[i] r_sel[i] r_warm[i] <<<"$line"
  done
  local med_root med_init med_pg med_sel med_warm
  med_root=$(median_ns "${r_root[@]}")
  med_init=$(median_ns "${r_init[@]}")
  med_pg=$(median_ns "${r_pg[@]}")
  med_sel=$(median_ns "${r_sel[@]}")
  med_warm=$(median_ns "${r_warm[@]}")
  if [ "$backend" = zig ]; then
    echo "zig_fuse|$(fmt_ms "$med_root")|$(fmt_ms "$med_init")|$(fmt_ms "$med_pg")|$(fmt_ms "$med_sel")|$(fmt_ms "$med_warm")"
  else
    echo "go_fuse|$(fmt_ms "$med_root")|$(fmt_ms "$med_init")|$(fmt_ms "$med_pg")|$(fmt_ms "$med_sel")|$(fmt_ms "$med_warm")"
  fi
}

main() {
  if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "run as root or with passwordless sudo" >&2
    exit 1
  fi
  ensure_image
  build_zig
  echo "backend|rootfs_ready_ms|initdb_ms|postgres_ready_ms|select1_cold_ms|select1_warm_ms"
  case "$BACKEND" in
    zig) run_backend zig ;;
    go) run_backend go ;;
    all)
      run_backend zig
      run_backend go
      ;;
    *) echo "usage: $0 [zig|go|all]" >&2; exit 1 ;;
  esac
}

main
