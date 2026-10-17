#!/usr/bin/env bash
# Benchmark PostgreSQL 16-alpine on Zig FUSE vs Go (voilad) FUSE rootfs.
# Cold: drop_caches, fresh mount process, empty PGDATA on tmpfs (3 runs, median).
# Phases: rootfs_ready, initdb, postgres_ready (log line), select1_cold, select1_warm.
#
# rootfs_ready: spawn mount -> /etc/os-release visible (excludes image import, zig build).
# postgres_ready: postgres start -> "database system is ready to accept connections" in log.
# select1_*: wall time for chroot+su-exec+psql from FUSE mount (includes binary exec), query only.
set -euo pipefail

BACKEND="${1:-all}" # zig | go | all
RUNS="${RUNS:-3}"
VOILA_ROOT="${VOILA_ROOT:-/tmp/voila-postgres-fuse}"
IMAGE_REF="${IMAGE_REF:-registry-1.docker.io/library/postgres:16-alpine}"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ZIG_FUSE="$REPO_ROOT/poc/zig-fuse"
ZIG_BIN="${ZIG_BIN:-zig}"
if ! command -v "$ZIG_BIN" >/dev/null 2>&1; then
  echo "zig not found on PATH (run mise install from the repo root)" >&2
  exit 1
fi
VOILA_BIN="${VOILA_BIN:-/tmp/voila}"
VOILAD_BIN="${VOILAD_BIN:-/tmp/voilad}"

PGDATA_IN_ROOT="/var/lib/postgresql/data"
PG_LOG_IN_CHROOT="/tmp/pgserver.log"
MNT_ZIG="${MNT_ZIG:-/tmp/zig-fuse-postgres-mnt}"
MNT_GO="${MNT_GO:-/tmp/go-fuse-postgres-mnt}"
POLL_MS="${POLL_MS:-10}"

now_ns() { date +%s%N; }

drop_caches() {
  sync
  local before after
  before=$(grep '^Cached:' /proc/meminfo)
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  after=$(grep '^Cached:' /proc/meminfo)
  echo "drop_caches: $before -> $after" >&2
}

MOUNT_PID=""
PG_PID=""

stop_postgres() {
  if [ -n "$PG_PID" ] && kill -0 "$PG_PID" 2>/dev/null; then
    sudo kill -TERM "$PG_PID" 2>/dev/null || true
    wait "$PG_PID" 2>/dev/null || true
  fi
  PG_PID=""
  sudo pkill -f "postgres -D $PGDATA_IN_ROOT" 2>/dev/null || true
  sleep 0.1
}

cleanup_mount() {
  stop_postgres
  if [ -n "$MOUNT_PID" ] && kill -0 "$MOUNT_PID" 2>/dev/null; then
    kill -TERM "$MOUNT_PID" 2>/dev/null || true
    wait "$MOUNT_PID" 2>/dev/null || true
  fi
  MOUNT_PID=""
  local mnt="$1"
  for mp in "$mnt/dev/shm" "$mnt/var/run/postgresql" "$mnt/tmp" "$mnt/sys" "$mnt/proc" "$mnt/dev" "$mnt$PGDATA_IN_ROOT" "$mnt"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      sudo umount "$mp" 2>/dev/null || sudo umount -l "$mp" 2>/dev/null || true
    fi
  done
  if mountpoint -q "$mnt" 2>/dev/null; then
    sudo fusermount3 -u "$mnt" 2>/dev/null || sudo umount "$mnt" 2>/dev/null || true
  fi
}

wait_probe_file() {
  local mnt="$1"
  local t0="$2"
  local probe="$mnt/etc/os-release"
  local deadline=$(( t0 + 120000000000 )) # 120s in ns
  while true; do
    if mountpoint -q "$mnt" 2>/dev/null && sudo test -f "$probe" 2>/dev/null; then
      echo "$(( $(now_ns) - t0 ))"
      return 0
    fi
    if [ "$(now_ns)" -gt "$deadline" ]; then
      echo "mount timeout waiting for $probe" >&2
      return 1
    fi
    sleep "$(awk -v ms="$POLL_MS" 'BEGIN{print ms/1000}')"
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
  sudo rm -f "$mnt$PG_LOG_IN_CHROOT"
}

assert_mount_clean() {
  local mnt="$1"
  if mountpoint -q "$mnt" 2>/dev/null; then
    echo "stale mount at $mnt before cold run" >&2
    cleanup_mount "$mnt"
  fi
  if sudo test -f "$mnt/etc/os-release" 2>/dev/null; then
    echo "stale os-release at $mnt before cold run" >&2
    return 1
  fi
}

start_zig_mount() {
  local mnt="$1"
  local zig="$ZIG_FUSE/zig-out/bin/zig-fuse"
  assert_mount_clean "$mnt"
  sudo mkdir -p "$mnt"
  local t0
  t0=$(now_ns)
  sudo "$zig" serve-store "$VOILA_ROOT" "$IMAGE_REF" "$mnt" >/tmp/zig-fuse-pg-bench.log 2>&1 &
  MOUNT_PID=$!
  wait_probe_file "$mnt" "$t0"
}

start_go_mount() {
  local mnt="$1"
  assert_mount_clean "$mnt"
  sudo mkdir -p "$mnt"
  local t0
  t0=$(now_ns)
  sudo "$VOILAD_BIN" mount -root "$VOILA_ROOT" -allow-other "$IMAGE_REF" "$mnt" >/tmp/voilad-pg-bench.log 2>&1 &
  MOUNT_PID=$!
  wait_probe_file "$mnt" "$t0"
}

wait_postgres_log_ready() {
  local mnt="$1"
  local t0="$2"
  local loghost="$mnt$PG_LOG_IN_CHROOT"
  local deadline=$(( t0 + 120000000000 ))
  while true; do
    if sudo grep -q 'database system is ready to accept connections' "$loghost" 2>/dev/null; then
      echo "$(( $(now_ns) - t0 ))"
      return 0
    fi
    if [ "$(now_ns)" -gt "$deadline" ]; then
      echo "postgres ready log timeout; tail:" >&2
      sudo tail -20 "$loghost" 2>/dev/null || true
      return 1
    fi
    sleep "$(awk -v ms="$POLL_MS" 'BEGIN{print ms/1000}')"
  done
}

run_psql_select1() {
  local mnt="$1"
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/psql -U postgres -tAc 'SELECT 1'
}

run_one_cold() {
  local backend="$1" # zig | go
  local mnt
  if [ "$backend" = zig ]; then
    mnt="$MNT_ZIG"
  else
    mnt="$MNT_GO"
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
    echo "$backend: cannot exec initdb from mount" >&2
    return 1
  fi

  local t_init
  t_init=$(now_ns)
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres /usr/local/bin/initdb \
    -D "$PGDATA_IN_ROOT" -U postgres --auth-host=trust --auth-local=trust >/dev/null 2>"$mnt/tmp/initdb.err" || {
    sudo cat "$mnt/tmp/initdb.err" >&2
    return 1
  }
  initdb_ns=$(( $(now_ns) - t_init ))

  local t_pg
  t_pg=$(now_ns)
  sudo chroot "$mnt" /usr/local/bin/su-exec postgres sh -c \
    "/usr/local/bin/postgres -D $PGDATA_IN_ROOT -c listen_addresses='' -c unix_socket_directories='/var/run/postgresql' >>$PG_LOG_IN_CHROOT 2>&1" &
  PG_PID=$!

  pg_ready_ns=$(wait_postgres_log_ready "$mnt" "$t_pg")

  local t_sel
  t_sel=$(now_ns)
  run_psql_select1 "$mnt" >/dev/null
  select1_ns=$(( $(now_ns) - t_sel ))

  t_sel=$(now_ns)
  run_psql_select1 "$mnt" >/dev/null
  select1_warm_ns=$(( $(now_ns) - t_sel ))

  cleanup_mount "$mnt"

  echo "raw|$backend|$rootfs_ns|$initdb_ns|$pg_ready_ns|$select1_ns|$select1_warm_ns"
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
    echo "Importing $IMAGE_REF (once, not timed) ..."
    "$VOILA_BIN" import -root "$VOILA_ROOT" docker.io/library/postgres:16-alpine
  fi
  echo "store=$VOILA_ROOT image=$IMAGE_REF" >&2
}

build_zig() {
  cd "$ZIG_FUSE"
  if [ ! -x "$ZIG_FUSE/zig-out/bin/zig-fuse" ]; then
    echo "Building zig-fuse (once, not timed) ..." >&2
    "$ZIG_BIN" build
  fi
}

run_backend() {
  local backend="$1"
  local -a r_root=() r_init=() r_pg=() r_sel=() r_warm=()
  local i line _tag _be a b c d e
  for i in $(seq 1 "$RUNS"); do
    echo "=== cold run $i/$RUNS ($backend) ===" >&2
    line=$(run_one_cold "$backend")
    echo "$line" >&2
    IFS='|' read -r _tag _be a b c d e <<<"$line"
    r_root+=("$a")
    r_init+=("$b")
    r_pg+=("$c")
    r_sel+=("$d")
    r_warm+=("$e")
  done
  local med_root med_init med_pg med_sel med_warm
  med_root=$(median_ns "${r_root[@]}")
  med_init=$(median_ns "${r_init[@]}")
  med_pg=$(median_ns "${r_pg[@]}")
  med_sel=$(median_ns "${r_sel[@]}")
  med_warm=$(median_ns "${r_warm[@]}")
  echo "median|$backend|$(fmt_ms "$med_root")|$(fmt_ms "$med_init")|$(fmt_ms "$med_pg")|$(fmt_ms "$med_sel")|$(fmt_ms "$med_warm")"
}

main() {
  if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "run as root or with passwordless sudo" >&2
    exit 1
  fi
  ensure_image
  build_zig
  echo "meta|store|$VOILA_ROOT"
  echo "meta|image|$IMAGE_REF"
  echo "meta|rootfs_probe|/etc/os-release"
  echo "meta|postgres_ready|log: database system is ready to accept connections"
  echo "meta|select1|chroot+su-exec+psql from FUSE mount (exec included)"
  echo "header|run|backend|rootfs_ready_ms|initdb_ms|postgres_ready_ms|select1_cold_ms|select1_warm_ms"
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
