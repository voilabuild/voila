#!/usr/bin/env python3
"""7-run rootfs-ready bench, four paths, drop_caches each run.

Guards: single-instance flock, per-run timeouts (no unbounded zig openTreeEager).
"""
import fcntl
import os
import re
import subprocess
import sys

ROOT = os.environ.get("VOILA_ROOT", "/tmp/voila-e2e-bench")
IMAGE = os.environ["VOILA_IMAGE"]
ZIG = os.environ["ZIG_VOILAD"]
ZF = os.environ["ZIG_FUSE"]
GO = os.environ["GO_BENCH"]
PROBE = os.environ.get("VOILA_PROBE", "etc/os-release")
RUNS = int(os.environ.get("VOILA_BENCH_RUNS", "7"))
LOCK_PATH = os.environ.get("VOILA_BENCH_LOCK", "/tmp/voilad-e2e-bench.lock")
TIMEOUT_FUSE = int(os.environ.get("VOILA_BENCH_TIMEOUT_FUSE", "90"))
TIMEOUT_EROFS = int(os.environ.get("VOILA_BENCH_TIMEOUT_EROFS", "120"))
TIMEOUT_ZIG_EROFS = int(os.environ.get("VOILA_BENCH_TIMEOUT_ZIG_EROFS", "90"))
SKIP_ZIG_EROFS = os.environ.get("VOILA_BENCH_SKIP_ZIG_EROFS", "") in ("1", "true", "yes")


def drop_caches():
    subprocess.run(["sync"], check=True)
    open("/proc/sys/vm/drop_caches", "w").write("3")


def cleanup():
    subprocess.run(["umount", "-l", "/tmp/zig-voilad-bench-mnt"], stderr=subprocess.DEVNULL)
    subprocess.run(["umount", "-l", "/tmp/go-voilad-bench-mnt"], stderr=subprocess.DEVNULL)
    for i in range(16):
        subprocess.run(["nbd-client", "-d", f"/dev/nbd{i}"], stderr=subprocess.DEVNULL)


def run_cmd(argv, timeout_sec: int):
    try:
        p = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout_sec,
        )
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT after {timeout_sec}s: {' '.join(argv[:3])}...", flush=True)
        cleanup()
        return None
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"rootfs_ready_ms=([0-9.]+)", out)
    return float(m.group(1)) if m else None


def bench(name, argv, timeout_sec: int):
    times = []
    for i in range(1, RUNS + 1):
        cleanup()
        drop_caches()
        ms = run_cmd(argv, timeout_sec)
        print(f"{name} run{i} {ms}", flush=True)
        if ms is not None:
            times.append(ms)
    if not times:
        return name, None, None, None
    times.sort()
    n = len(times)
    med = times[n // 2] if n % 2 else (times[n // 2 - 1] + times[n // 2]) / 2
    return name, med, times[0], times[-1]


def acquire_lock():
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"another voilad bench is already running (lock {LOCK_PATH})", file=sys.stderr)
        sys.exit(3)
    return fd


def main():
    if os.geteuid() != 0:
        print("run as root", file=sys.stderr)
        sys.exit(2)
    lock_fd = acquire_lock()
    try:
        rows = []
        rows.append(
            bench(
                "zig-fuse",
                [ZIG, "bench-once", "-root", ROOT, "-image", IMAGE, "-backend", "fuse", "-probe", PROBE, "-zig-fuse", ZF],
                TIMEOUT_FUSE,
            )
        )
        rows.append(
            bench(
                "go-fuse",
                [GO, "-root", ROOT, "-image", IMAGE, "-backend", "fuse", "-probe", PROBE],
                TIMEOUT_FUSE,
            )
        )
        rows.append(
            bench(
                "go-erofs",
                [GO, "-root", ROOT, "-image", IMAGE, "-backend", "erofs", "-probe", PROBE],
                TIMEOUT_EROFS,
            )
        )
        if SKIP_ZIG_EROFS:
            rows.append(("zig-erofs", None, None, None))
            print("zig-erofs skipped (VOILA_BENCH_SKIP_ZIG_EROFS)", flush=True)
        else:
            rows.append(
                bench(
                    "zig-erofs",
                    [
                        ZIG,
                        "bench-once",
                        "-root",
                        ROOT,
                        "-image",
                        IMAGE,
                        "-backend",
                        "erofs",
                        "-probe",
                        PROBE,
                        "-zig-fuse",
                        ZF,
                    ],
                    TIMEOUT_ZIG_EROFS,
                )
            )
        cleanup()
        print("\n| Path | median ms | min–max ms |")
        print("|------|-----------|------------|")
        for name, med, lo, hi in rows:
            if med is None:
                print(f"| {name} | n/a | n/a |")
            else:
                print(f"| {name} | {med:.3f} | {lo:.3f}–{hi:.3f} |")
    finally:
        cleanup()
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    main()
