#!/bin/bash
# One-time devcontainer setup: runtime + FUSE + image tooling for voila.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
# runc: container runtime invoked by `voila run` (milestone 4).
# fuse3: /dev/fuse userspace tools for the mount daemon (milestone 3).
# skopeo: daemonless image pulls for e2e fixtures
#   (skopeo copy docker://alpine:3.20 oci-archive:/tmp/alpine.tar).
apt-get install -y --no-install-recommends runc fuse3 skopeo

# FUSE allow_other (we run as root, but keep the config explicit).
if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    echo 'user_allow_other' >> /etc/fuse.conf
fi

# mise: provision the Go toolchain + codegen tools (buf, protoc-gen-go,
# protoc-gen-go-grpc) from the pinned, checksum-locked .mise.toml + mise.lock.
# See doc/DEV_SETUP.md. This replaces the previous `go install ...@latest` lines
# so the devcontainer and the Linux-native path use the exact same versions.
if ! command -v mise >/dev/null 2>&1; then
    curl -fsSL https://mise.run | sh
fi
# shellcheck disable=SC1090
eval "$("$HOME/.local/bin/mise" activate bash)"
mise install
echo 'eval "$("$HOME/.local/bin/mise" activate bash)"' >> "$HOME/.bashrc"

echo "post-create done: $(runc --version | head -1), $(skopeo --version), $(go version), $(buf --version 2>&1 | head -1)"
