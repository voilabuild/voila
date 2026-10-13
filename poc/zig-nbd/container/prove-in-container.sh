#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "container must run as root (docker run --privileged)" >&2
  exit 1
fi

if ! modprobe nbd max_part=8 2>/dev/null; then
  echo "modprobe nbd failed: kernel module missing on this host (container shares host modules)" >&2
  exit 2
fi

if [[ ! -e /dev/nbd0 ]]; then
  echo "/dev/nbd0 not present after modprobe nbd" >&2
  exit 3
fi

cd /voila/poc/zig-nbd
zig build
zig build test
./zig-out/bin/zig-nbd prove fixture-out
