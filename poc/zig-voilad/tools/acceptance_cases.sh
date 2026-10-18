#!/usr/bin/env bash
# Run acceptance cases on an already-mounted image tree.
# Usage: acceptance_cases.sh <mountpoint> <golden_dir>
# Emits: accept_case=<name> pass=0|1 [detail=...] [hello_wall_ms=...]
set -euo pipefail

MNT="${1:?mountpoint}"
GOLDEN="${2:?golden_dir}"
BACKEND="${VOILA_ACCEPT_BACKEND:-unknown}"

PYTHON="${MNT}/usr/local/bin/python3"
SYMLINK="${MNT}/usr/bin/python3"
NESTED="${MNT}/etc/os-release"
MULTI="${MNT}/usr/local/lib/libpython3.13.so.1.0"
PASSWD="${MNT}/etc/passwd"
SU="${MNT}/usr/bin/su"

emit() {
  local name="$1" pass="$2" extra="${3:-}"
  if [[ -n "$extra" ]]; then
    echo "accept_case=${name} pass=${pass} backend=${BACKEND} ${extra}"
  else
    echo "accept_case=${name} pass=${pass} backend=${BACKEND}"
  fi
}

case_hello() {
  if [[ ! -x "$PYTHON" ]]; then
    emit hello 0 "detail=python_missing"
    return 1
  fi
  local t0 t1 out ms
  t0=$(date +%s%N)
  if ! out="$("$PYTHON" -c 'print("hello")' 2>&1)"; then
    emit hello 0 "detail=exec_failed:${out}"
    return 1
  fi
  t1=$(date +%s%N)
  ms=$(awk -v d="$((t1 - t0))" 'BEGIN{printf "%.3f", d/1000000000}')
  if [[ "$out" != "hello" ]]; then
    emit hello 0 "detail=bad_output:${out}" "hello_wall_ms=${ms}"
    return 1
  fi
  emit hello 1 "hello_wall_ms=${ms}"
}

golden_hash_file() {
  local name="$1" path="$2"
  local hash
  hash=$(sha256sum "$path" | awk '{print $1}')
  mkdir -p "$GOLDEN"
  local gf="${GOLDEN}/${name}.sha256"
  if [[ ! -f "$gf" ]]; then
    echo "$hash" >"$gf"
    return 0
  fi
  [[ "$(cat "$gf")" == "$hash" ]]
}

golden_hash_prefix() {
  local name="$1" path="$2" nbytes="$3"
  local hash
  hash=$(head -c "$nbytes" "$path" | sha256sum | awk '{print $1}')
  mkdir -p "$GOLDEN"
  local gf="${GOLDEN}/${name}.sha256"
  if [[ ! -f "$gf" ]]; then
    echo "$hash" >"$gf"
    return 0
  fi
  [[ "$(cat "$gf")" == "$hash" ]]
}

case_symlink() {
  if [[ ! -L "$SYMLINK" ]]; then
    emit symlink 0 "detail=not_symlink"
    return 1
  fi
  local target
  target=$(readlink "$SYMLINK")
  if [[ "$target" != "python3.13" ]]; then
    emit symlink 0 "detail=target:${target}"
    return 1
  fi
  if [[ ! -e "${MNT}/bin/python3.13" ]]; then
    emit symlink 0 "detail=target_missing"
    return 1
  fi
  emit symlink 1
}

case_nested() {
  if [[ ! -f "$NESTED" ]]; then
    emit nested 0 "detail=missing"
    return 1
  fi
  if ! golden_hash_file "etc_os-release" "$NESTED"; then
    emit nested 0 "detail=hash_mismatch"
    return 1
  fi
  emit nested 1
}

case_multichunk() {
  if [[ ! -f "$MULTI" ]]; then
    emit multichunk 0 "detail=missing"
    return 1
  fi
  if ! golden_hash_prefix "libpython_1mb" "$MULTI" 1048576; then
    emit multichunk 0 "detail=hash_mismatch"
    return 1
  fi
  emit multichunk 1
}

case_permissions() {
  local mode_p uid_p gid_p mode_s uid_s gid_s
  if [[ ! -f "$PASSWD" ]] || [[ ! -f "$SU" ]]; then
    emit permissions 0 "detail=missing_file"
    return 1
  fi
  mode_p=$(stat -c '%a' "$PASSWD")
  uid_p=$(stat -c '%u' "$PASSWD")
  gid_p=$(stat -c '%g' "$PASSWD")
  mode_s=$(stat -c '%a' "$SU")
  uid_s=$(stat -c '%u' "$SU")
  gid_s=$(stat -c '%g' "$SU")
  if [[ "$mode_p" != "644" || "$uid_p" != "0" || "$gid_p" != "0" ]]; then
    emit permissions 0 "detail=passwd:${mode_p}/${uid_p}/${gid_p}"
    return 1
  fi
  if [[ "$mode_s" != "4755" || "$uid_s" != "0" || "$gid_s" != "0" ]]; then
    emit permissions 0 "detail=su:${mode_s}/${uid_s}/${gid_s}"
    return 1
  fi
  emit permissions 1
}

FAIL=0
case_hello || FAIL=1
case_symlink || FAIL=1
case_nested || FAIL=1
case_multichunk || FAIL=1
case_permissions || FAIL=1

if [[ "$FAIL" -eq 0 ]]; then
  echo "accept_backend=${BACKEND} pass=1"
else
  echo "accept_backend=${BACKEND} pass=0"
fi
exit "$FAIL"
