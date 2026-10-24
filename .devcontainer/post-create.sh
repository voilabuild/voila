#!/bin/bash
# One-time devcontainer setup: FUSE, subid helpers and the pinned Zig toolchain.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
# fuse3: fusermount3 for the per-container FUSE server.
# uidmap: newuidmap/newgidmap for subid-range user namespaces in RUN.
apt-get install -y --no-install-recommends fuse3 uidmap

if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    echo 'user_allow_other' >> /etc/fuse.conf
fi

# mise provisions the pinned zig from .mise.toml + mise.lock.
if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.run | sh
fi
# shellcheck disable=SC1090
eval "$("$HOME/.local/bin/mise" activate bash)"
mise install
echo 'eval "$("$HOME/.local/bin/mise" activate bash)"' >> "$HOME/.bashrc"

echo "post-create done: zig $(zig version), $(uv --version)"
