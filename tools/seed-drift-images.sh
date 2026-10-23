#!/usr/bin/env bash
# Seed common Docker Hub images into drift under $VOILA_ORG via `voila import`.
set -euo pipefail

: "${VOILA_REGISTRY:?set VOILA_REGISTRY (…/registry)}"
: "${VOILA_REGISTRY_TOKEN:?set VOILA_REGISTRY_TOKEN}"
: "${VOILA_ORG:?set VOILA_ORG}"

VOILA="${VOILA:-voila}"
if ! command -v "$VOILA" >/dev/null 2>&1; then
	echo "seed-drift-images: missing voila in PATH (set VOILA=…)" >&2
	exit 1
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
		"$VOILA" import -root "$ROOT" "$img"
done
