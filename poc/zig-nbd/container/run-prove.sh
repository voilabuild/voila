#!/usr/bin/env bash
# Run the full prove path (mount + boundary bytes) in a privileged container.
# Requires: Docker, host kernel with nbd module (modprobe nbd works on the host).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
IMAGE="${ZIG_NBD_IMAGE:-zig-nbd-prove:latest}"

docker_cmd=(docker)
if ! docker info &>/dev/null; then
  docker_cmd=(sudo docker)
fi

"${docker_cmd[@]}" build -f "$ROOT/poc/zig-nbd/container/Dockerfile" -t "$IMAGE" "$ROOT"

"${docker_cmd[@]}" run --rm --privileged \
  -v "$ROOT:/voila" \
  -w /voila \
  "$IMAGE"
