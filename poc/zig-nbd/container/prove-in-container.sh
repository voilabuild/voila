#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "container must run as root (docker run --privileged)" >&2
  exit 1
fi

nbd_ok=0
if modprobe nbd max_part=8 2>/dev/null && [[ -e /dev/nbd0 ]]; then
  nbd_ok=1
else
  echo "warn: modprobe nbd failed or /dev/nbd0 missing (container uses host kernel modules)" >&2
  echo "warn: will run zig build test + prove readAt path only; mount step skipped" >&2
fi

fixture="/voila/poc/zig-nbd/fixture-out"
if [[ ! -f "$fixture/meta.bin" ]]; then
  echo "generating fixture with Go..."
  (cd /voila && go run -tags zig_nbd_fixture ./poc/zig-nbd/fixture -o poc/zig-nbd/fixture-out)
fi

cd /voila/poc/zig-nbd
zig build
zig build test
./zig-out/bin/zig-nbd prove fixture-out

if [[ "$nbd_ok" -eq 1 ]]; then
  echo "container prove: mount path exercised (nbd + erofs)"
else
  echo "container prove: mount skipped (no nbd module on host kernel)"
  exit 2
fi
