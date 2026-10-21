#!/usr/bin/env bash
# Seed common Docker Hub images into drift under $VOILA_ORG (fallback when voila-import is unavailable).
set -euo pipefail

: "${VOILA_REGISTRY:?set VOILA_REGISTRY (…/registry)}"
: "${VOILA_REGISTRY_TOKEN:?set VOILA_REGISTRY_TOKEN}"
: "${VOILA_ORG:?set VOILA_ORG}"

HELPER="${VOILA_IMPORT_HELPER:-${HOME}/.local/lib/voila/voila-import}"
if ! command -v "$HELPER" >/dev/null 2>&1 && [ ! -x "$HELPER" ]; then
	die() { echo "seed-drift-images: $*" >&2; exit 1; }
	die "missing voila-import at $HELPER (install via install.sh or set VOILA_IMPORT_HELPER)"
fi

IMAGES=(
	alpine
	busybox
	ubuntu:24.04
	debian:bookworm-slim
	nginx
	python:3.13
	node:22
	redis
	postgres:17
)

ROOT="${VOILA_SEED_ROOT:-/tmp/voila-seed-drift}"
mkdir -p "$ROOT"

for img in "${IMAGES[@]}"; do
	echo "==> $img"
	VOILA_REGISTRY="$VOILA_REGISTRY" VOILA_REGISTRY_TOKEN="$VOILA_REGISTRY_TOKEN" VOILA_ORG="$VOILA_ORG" \
		"$HELPER" import "$img" -push "${VOILA_ORG}/${img}" -root "$ROOT" -registry "$VOILA_REGISTRY"
done
