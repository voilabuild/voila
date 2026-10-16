#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG_OBJ="$1"
OUT="$ROOT/zig-out/bin/zig-voilad"
mkdir -p "$(dirname "$OUT")"
GRPC_LIBS="$(pkg-config --libs grpc++ protobuf)"
g++ -std=c++17 -o "$OUT" "$ZIG_OBJ" "$ROOT/build/grpc/libvoilad_grpc.a" $GRPC_LIBS -lsqlite3 -pthread
