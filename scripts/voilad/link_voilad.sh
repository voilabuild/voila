#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_OBJ="$1"
OUT="$ROOT/zig-out/bin/zig-voilad"
mkdir -p "$(dirname "$OUT")"
GRPC_LIBS="$(pkg-config --libs grpc libprotobuf-c)"
CURL_OBJ="$ROOT/build/curl_shim.o"
mkdir -p "$ROOT/build"
gcc -std=c11 -c "$ROOT/../zig-fuse/src/curl_shim.c" -o "$CURL_OBJ"
gcc -std=c11 -o "$OUT" "$ZIG_OBJ" "$CURL_OBJ" "$ROOT/build/grpc/libvoilad_grpc.a" $GRPC_LIBS -lsqlite3 -lcurl -pthread
