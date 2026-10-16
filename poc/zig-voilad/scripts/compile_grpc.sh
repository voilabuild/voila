#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/grpc"
mkdir -p "$OUT"
g++ -std=c++17 -fPIC -I"$ROOT/proto/cpp" -I"$ROOT/src" -c \
  "$ROOT/proto/cpp/worker_run.pb.cc" -o "$OUT/worker_run.pb.o"
g++ -std=c++17 -fPIC -I"$ROOT/proto/cpp" -I"$ROOT/src" -c \
  "$ROOT/proto/cpp/worker_run.grpc.pb.cc" -o "$OUT/worker_run.grpc.pb.o"
g++ -std=c++17 -fPIC -I"$ROOT/proto/cpp" -I"$ROOT/src" -c \
  "$ROOT/src/grpc_worker_shim.cpp" -o "$OUT/grpc_worker_shim.o"
ar rcs "$OUT/libvoilad_grpc.a" "$OUT/worker_run.pb.o" "$OUT/worker_run.grpc.pb.o" "$OUT/grpc_worker_shim.o"
