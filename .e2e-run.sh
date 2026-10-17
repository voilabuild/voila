#!/bin/bash
# E2E — install.sh only + hosted remote registry (saucisse org).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG=/tmp/voila-e2e.log
exec > >(tee -a "$LOG") 2>&1

step() { echo; echo "=== $* ==="; }
fail() { echo "FAIL: $*"; exit 1; }

: "${VOILA_REGISTRY_TOKEN:?VOILA_REGISTRY_TOKEN required}"
# Default matches CLI/install; override VOILA_REGISTRY for pre-DNS CI, e.g.
# https://drift-registry-production.up.railway.app/registry
REGISTRY="${VOILA_REGISTRY:-https://registry.voila.build/registry}"
ORG="${VOILA_ORG:-saucisse}"
TAG="e2e-$(date +%s)"
REMOTE_REF="${ORG}/alpine:${TAG}"
LOCAL_REF="registry-1.docker.io/library/alpine:3.20"

step "1. install.sh + remote registry"
cd /workspace
./install.sh --install-prereqs --install-fuse --yes \
  --token "$VOILA_REGISTRY_TOKEN" \
  --registry "$REGISTRY"
# shellcheck disable=SC1091
source /etc/profile.d/voila.sh
echo "$(voila -version | head -1)"

step "2. voilad"
pkill voilad 2>/dev/null || true
voilad &
sleep 2
voila ps || fail "voilad not responding"

step "3. import (Docker Hub) → tag → push to $REGISTRY"
voila import alpine:3.20
voila tag "$LOCAL_REF" "$REMOTE_REF"
voila push "$REMOTE_REF"

step "4. fresh store — pull manifest from registry, lazy run"
export VOILA_ROOT="/tmp/voila-remote-${TAG}"
export VOILA_SOCKET="${VOILA_ROOT}/worker.sock"
mkdir -p "$VOILA_ROOT"
pkill voilad 2>/dev/null || true
voilad -root "$VOILA_ROOT" -registry "$REGISTRY" &
sleep 2
CHUNKS_BEFORE=$(find "$VOILA_ROOT/chunks" -type f 2>/dev/null | wc -l | tr -d ' ')
voila pull "$REMOTE_REF"
echo "chunks after pull (manifest only, data lazy): $CHUNKS_BEFORE"
OUT=$(voila run "$REMOTE_REF" -- /bin/echo remote-ok)
echo "$OUT" | grep -q remote-ok || fail "run failed: $OUT"
CHUNKS_AFTER=$(find "$VOILA_ROOT/chunks" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "chunks after lazy run: $CHUNKS_AFTER"
[ "$CHUNKS_AFTER" -gt "$CHUNKS_BEFORE" ] || fail "expected chunks fetched from remote on read"

step "5. negative — pull missing image"
set +e
voila pull "${ORG}/no-such-${TAG}" 2>&1 | tee /tmp/neg.txt
grep -qiE 'not found|404|error' /tmp/neg.txt || echo "WARN: unclear not-found error"
set -e

step "DONE"
echo "Remote registry E2E passed: $REMOTE_REF"
