#!/bin/bash
# voila build acceptance: COPY/RUN/ENV/WORKDIR, whiteouts, opaque dirs,
# .dockerignore, step cache, invalidation and RUN failure reporting.
# Fully local: FROM scratch + a static busybox, no registry or network.
#
#   test/gates/build.sh [path/to/voila]
#
# Needs /dev/fuse, fusermount3 and unprivileged user namespaces for the
# voila binary (on Ubuntu 24.04+, the install.sh AppArmor profile is bound
# to the installed path, so pass that binary).
set -euo pipefail

VOILA=${1:-voila}
BUSYBOX=${BUSYBOX:-/usr/bin/busybox}
file -L "$BUSYBOX" | grep -q 'statically linked' || { echo "need a static busybox (set BUSYBOX)"; exit 2; }

WORK=$(mktemp -d /tmp/voila-build-gate.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ROOT=$WORK/root CTX=$WORK/ctx
mkdir -p "$ROOT" "$CTX/etc"
cp "$BUSYBOX" "$CTX/busybox"
echo hi >"$CTX/hello.txt"
echo secret >"$CTX/secret.txt"
echo welcome >"$CTX/etc/motd"
echo secret.txt >"$CTX/.dockerignore"
cat >"$CTX/Dockerfile" <<'EOF'
FROM scratch
COPY busybox /bin/busybox
RUN ["/bin/busybox", "--install", "-s", "/bin"]
COPY etc/ /etc/
ENV GREETING=bonjour
COPY *.txt /app/
RUN rm /etc/motd && mkdir -p /var/cache/old && echo stale > /var/cache/old/x && echo "$GREETING" > /app/run.txt
RUN rm -rf /var/cache && mkdir -p /var/cache/new
WORKDIR /app
CMD ["/bin/sh", "-c", "echo $GREETING"]
EOF

build() { "$VOILA" build -root "$ROOT" -t test/gate:1 "$CTX" 2>&1 | grep -v SafeAllocator; }
inside() { "$VOILA" run --rm -w /app -root "$ROOT" test/gate:1 /bin/busybox sh -c "$1" 2>/dev/null | grep -v SafeAllocator; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; exit 1; fi; }

echo "=== cold build"
out=$(build); echo "$out"
check "cold build caches nothing" "$(echo "$out" | grep -c CACHED || true)" 0

echo "=== image contents"
check "ENV reaches RUN and run" "$(inside 'cat run.txt; echo $GREETING' | tr '\n' ' ')" "bonjour bonjour "
check "whiteout removes /etc/motd" "$(inside 'ls /etc/motd 2>/dev/null; echo done')" "done"
check "opaque dir hides old entries" "$(inside 'ls /var/cache')" "new"
check ".dockerignore excludes secret.txt" "$(inside 'ls /app | tr "\n" " "')" "hello.txt run.txt "
check "RUN uses umask 022" "$(inside 'stat -c %a /var/cache/new')" "755"

echo "=== warm rebuild"
out=$(build)
check "warm rebuild caches every layer step" "$(echo "$out" | grep -c CACHED)" 6

echo "=== context change"
echo hello-v2 >"$CTX/hello.txt"
out=$(build)
check "only steps from the changed COPY rerun" "$(echo "$out" | grep -c CACHED)" 3

echo "=== failing RUN"
mkdir -p "$WORK/bad"
printf 'FROM test/gate:1\nRUN exit 3\n' >"$WORK/bad/Dockerfile"
if out=$("$VOILA" build -root "$ROOT" -t test/bad:1 "$WORK/bad" 2>&1); then echo "FAIL failing RUN succeeded"; exit 1; fi
echo "$out" | grep -q 'Dockerfile:2: RUN command failed (exit status 3)' && echo "ok   failing RUN reports line and status"

echo "build gate: all checks passed"
