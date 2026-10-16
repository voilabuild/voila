#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/grpc"
PB_C="$OUT/pb-c"
mkdir -p "$OUT" "$PB_C"

protoc -I"$ROOT/proto" --c_out="$PB_C" "$ROOT/proto/worker_run.proto"

GRPC_CFLAGS="$(pkg-config --cflags grpc libprotobuf-c)"
GRPC_LIBS="$(pkg-config --libs grpc libprotobuf-c)"

gcc -std=c11 -fPIC $GRPC_CFLAGS -I"$PB_C" -I"$ROOT/src" -c \
  "$PB_C/worker_run.pb-c.c" -o "$OUT/worker_run.pb-c.o"
gcc -std=c11 -fPIC $GRPC_CFLAGS -I"$PB_C" -I"$ROOT/src" -c \
  "$ROOT/src/grpc_worker_shim.c" -o "$OUT/grpc_worker_shim.o"

ar rcs "$OUT/libvoilad_grpc.a" "$OUT/worker_run.pb-c.o" "$OUT/grpc_worker_shim.o"
