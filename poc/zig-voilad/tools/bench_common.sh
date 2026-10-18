# Shared guards for voilad E2E benches (source from bash drivers).
# Prevents overlapping runs and unbounded CPU (e.g. cold openTreeEager on huge images).

: "${VOILA_BENCH_LOCK:=/tmp/voilad-e2e-bench.lock}"
: "${VOILA_BENCH_TIMEOUT_FUSE:=90}"
: "${VOILA_BENCH_TIMEOUT_EROFS:=120}"
: "${VOILA_BENCH_TIMEOUT_ZIG_EROFS:=90}"
: "${VOILA_BENCH_TIMEOUT_COLD:=120}"

bench_acquire_lock() {
  exec 9>"$VOILA_BENCH_LOCK"
  if ! flock -n 9; then
    echo "another voilad bench is already running (lock $VOILA_BENCH_LOCK)" >&2
    exit 3
  fi
}

bench_release_lock() {
  flock -u 9 2>/dev/null || true
}

bench_cleanup_mounts() {
  umount -l /tmp/zig-voilad-bench-mnt 2>/dev/null || true
  umount -l /tmp/go-voilad-bench-mnt 2>/dev/null || true
  if command -v nbd-client >/dev/null 2>&1; then
    for i in $(seq 0 15); do
      nbd-client -d "/dev/nbd$i" 2>/dev/null || true
    done
  fi
}

bench_on_exit() {
  bench_cleanup_mounts
  bench_release_lock
}

bench_trap_setup() {
  trap bench_on_exit EXIT INT TERM
}

# Run a command with timeout; kills the process group on expiry.
bench_timeout_run() {
  local secs="$1"
  shift
  if ! command -v timeout >/dev/null 2>&1; then
    echo "timeout(1) required for voilad benches" >&2
    exit 2
  fi
  timeout --signal=TERM --kill-after=10 "${secs}" "$@"
}
