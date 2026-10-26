#!/usr/bin/env bash
# Homelab smoke after install (or from source with VOILA_BIN set).
set -euo pipefail

VOILA="${VOILA_BIN:-${HOME}/.local/bin/voila}"
if [[ ! -x "$VOILA" ]]; then
	VOILA="${VOILA_BIN:-voila}"
fi
command -v "$VOILA" >/dev/null || {
	echo "acceptance: no voila binary (set VOILA_BIN or run install.sh)" >&2
	exit 1
}

ROOT="${VOILA_ACCEPT_ROOT:-$(mktemp -d)}"
export VOILA_ROOT="$ROOT"
trap 'rm -rf "$ROOT"' EXIT

echo "==> voila: $("$VOILA" --help 2>&1 | head -1 || true)"
echo "==> import alpine:3.20"
"$VOILA" import alpine:3.20
echo "==> run hello"
out="$("$VOILA" run --rm alpine:3.20 -- echo voila-alpha-ok)"
[[ "$out" == *voila-alpha-ok* ]] || {
	echo "unexpected output: $out" >&2
	exit 1
}
echo "==> acceptance ok"
