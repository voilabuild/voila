#!/bin/bash
# install.sh — one-shot installer for the voila Zig CLI (zig-fuse) on Linux.
#
# What it does:
#   1. Verifies prerequisites (OS, arch, curl/sha256sum, fuse3, runc).
#   2. Resolves the latest `v*` release tag from GitHub (or pins to --version).
#   3. Downloads the per-arch zig-fuse binary + zig-fuse-checksums.txt and verifies SHA256.
#   4. Installs zig-fuse into --prefix (default /usr/local/bin).
#   5. Enables user_allow_other in /etc/fuse.conf when possible (one-time root), so
#      zig-fuse can pass allow_other and container UIDs can use the FUSE rootfs.
#   6. Optionally configures VOILA_ROOT / registry env in /etc/profile.d/voila.sh.
#
# The Zig CLI is daemonless and rootless: `zig-fuse run` mounts via FUSE and invokes
# runc without voilad. Linux amd64/arm64 only.
#
# Usage:
#   curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sudo bash
#   # or, from a clone:
#   sudo ./install.sh [--version v0.1.0] [--prefix /usr/local/bin] [--yes]
#
# Flags:
#   --version <tag>      Pin to a specific release tag (default: latest).
#   --prefix <dir>       Install directory (default: /usr/local/bin).
#   --token <key>        Registry API key (dreg_...) for auth; asks interactively if omitted.
#   --install-prereqs    Install missing runc/fuse3 via the distro package manager.
#   --yes                Assume yes to prompts (non-interactive).
#   -h, --help           Show this help.

set -euo pipefail

REPO="voilabuild/voila"
PREFIX="/usr/local/bin"
VERSION=""
INSTALL_PREREQS=0
ASSUME_YES=0
TOKEN=""
REGISTRY_URL="https://drift-registry-production.up.railway.app/registry"

usage() {
	sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,/^$/p' || true
	cat <<'EOF'

Flags:
  --version <tag>      Pin to a specific release tag (default: latest).
  --prefix <dir>       Install directory (default: /usr/local/bin).
  --registry <url>     Remote chunk registry (default: hosted drift registry; "" = offline).
  --token <key>        Registry API key (dreg_...) for push/private images.
  --install-prereqs    Install missing runc/fuse3 via apt-get/dnf/yum/zypper.
  --yes                Assume yes to prompts (non-interactive).
  -h, --help           Show this help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:-}"; shift 2 ;;
		--prefix)  PREFIX="${2:-}"; shift 2 ;;
		--registry) REGISTRY_URL="${2:-}"; shift 2 ;;
		--token)    TOKEN="${2:-}"; shift 2 ;;
		--install-prereqs) INSTALL_PREREQS=1; shift ;;
		--yes|-y) ASSUME_YES=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "install.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
	esac
done

# --- helpers --------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: '$1'. Install it and re-run."
}

CURL_AUTH=()
for _t in GITHUB_TOKEN GH_TOKEN FORGEJO_TOKEN; do
	if [ -n "${!_t:-}" ]; then CURL_AUTH=(-H "Authorization: Bearer ${!_t}"); break; fi
done
curl_auth() { curl "${CURL_AUTH[@]}" "$@"; }

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	local prompt="$1 [y/N] " reply
	if [ -t 0 ]; then
		read -r -p "$prompt" reply
	else
		if ! read -r -p "$prompt" reply < /dev/tty; then
			die "missing a required prerequisite and no terminal is available (piped install). Re-run with --install-prereqs or --yes."
		fi
	fi
	[[ "$reply" =~ ^[Yy]$ ]]
}

# --- 1. prerequisite checks ----------------------------------------------

log "checking prerequisites"

case "$(uname -s)" in
	Linux) : ;;
	*) die "this installer is Linux-only (detected $(uname -s)). zig-fuse needs runc + FUSE on Linux." ;;
esac

case "$(uname -m)" in
	x86_64|amd64) ARCH=amd64 ;;
	aarch64|arm64) ARCH=arm64 ;;
	*) die "unsupported architecture: $(uname -m) (zig-fuse releases: linux amd64 / arm64)" ;;
esac

need_cmd curl
need_cmd sha256sum
need_cmd uname

if [ -w "$PREFIX" ] || [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	need_cmd sudo
	SUDO="sudo"
fi

check_runtime_prereqs() {
	local missing=0
	if ! command -v runc >/dev/null 2>&1; then
		warn "runc not found — 'zig-fuse run' needs it for containers."
		missing=1
	fi
	if [ ! -e /dev/fuse ]; then
		warn "/dev/fuse not found — zig-fuse cannot mount images."
		missing=1
	fi
	if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
		warn "fuse3 not found (no fusermount3/fusermount) — install fuse3."
		missing=1
	fi
	return $missing
}

detect_pkgmgr() {
	if command -v apt-get >/dev/null 2>&1; then echo "apt-get"
	elif command -v dnf >/dev/null 2>&1; then echo "dnf"
	elif command -v yum >/dev/null 2>&1; then echo "yum"
	elif command -v zypper >/dev/null 2>&1; then echo "zypper"
	else echo ""; fi
}

pkg_install() {
	local mgr
	mgr="$(detect_pkgmgr)"
	[ -n "$mgr" ] || die "no supported package manager (apt-get, dnf/yum, zypper). Install '$*' manually."
	log "installing via $mgr: $*"
	case "$mgr" in
		apt-get)
			$SUDO apt-get update -y
			DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@"
			;;
		dnf|yum) $SUDO "$mgr" install -y "$@" ;;
		zypper) $SUDO zypper --non-interactive install "$@" ;;
	esac
}

if ! check_runtime_prereqs; then
	if [ "$INSTALL_PREREQS" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
		log "installing runtime prerequisites (runc, fuse3)"
		pkg_install runc fuse3
		check_runtime_prereqs || warn "some runtime prerequisites still missing"
	elif confirm "install missing prerequisites (runc, fuse3) via your package manager?"; then
		pkg_install runc fuse3
		check_runtime_prereqs || warn "some runtime prerequisites still missing"
	else
		warn "skipping prerequisite install; runc/fuse3 may be missing at use time."
		confirm "continue anyway?" || die "aborted by user"
	fi
fi

ensure_user_allow_other() {
	if [ -f /etc/fuse.conf ] && grep -q '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		return 0
	fi
	if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
		warn "/etc/fuse.conf is missing 'user_allow_other' — zig-fuse will mount rootless without allow_other."
		warn "  container UIDs may not execute from the FUSE rootfs. Re-run this installer with sudo to fix, or add the line manually."
		return 0
	fi
	log "configuring /etc/fuse.conf (user_allow_other)"
	if [ ! -f /etc/fuse.conf ]; then
		echo 'user_allow_other' | $SUDO tee /etc/fuse.conf >/dev/null
		return 0
	fi
	if ! grep -q '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		$SUDO sed -i 's/^# *user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null || true
	fi
	if ! grep -q '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		echo 'user_allow_other' | $SUDO tee -a /etc/fuse.conf >/dev/null
	fi
}

ensure_user_allow_other

# --- 2. resolve the latest tag -------------------------------------------

if [ -z "$VERSION" ]; then
	log "resolving latest release tag from github.com/$REPO"
	VERSION="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
		| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	if [ -z "$VERSION" ]; then
		VERSION="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=1" \
			| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	fi
	[ -n "$VERSION" ] || die "could not resolve latest release tag from GitHub API"
fi
log "using release $VERSION (linux/$ARCH)"

# --- 3. download + verify checksum ---------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BINARY="zig-fuse_${VERSION}_linux_${ARCH}"

fetch_asset() {
	local name="$1" out="$2"
	local simple="https://github.com/${REPO}/releases/download/${VERSION}/${name}"
	if curl_auth -fsSL -o "$out" "$simple" 2>/dev/null; then
		return 0
	fi
	[ "${#CURL_AUTH[@]}" -gt 0 ] || die "download failed: $simple"
	log "private repo: resolving $name via GitHub API"
	local meta asset_url
	meta="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" \
		|| die "could not fetch release metadata from GitHub API"
	asset_url="$(printf '%s\n' "$meta" | awk -v want="$name" '
		/"url":[[:space:]]*"/ {
			line=$0; sub(/.*"url":[[:space:]]*"/,"",line); sub(/".*/,"",line); url=line
		}
		/"name":[[:space:]]*"/ {
			line=$0; sub(/.*"name":[[:space:]]*"/,"",line); sub(/".*/,"",line)
			if (line==want) { print url; exit }
		}')"
	[ -n "$asset_url" ] || die "could not find asset '$name' in release $VERSION"
	curl -sSL "${CURL_AUTH[@]}" -H "Accept: application/octet-stream" \
		-o "$out" "$asset_url" || die "download failed: $asset_url"
}

log "downloading $BINARY"
fetch_asset "$BINARY" "$WORK/$BINARY"
fetch_asset "zig-fuse-checksums.txt" "$WORK/zig-fuse-checksums.txt"

log "verifying sha256"
( cd "$WORK" && grep -F "$BINARY" zig-fuse-checksums.txt | sha256sum -c ) \
	|| die "checksum verification failed — the download may be corrupt or tampered with"

# --- 4. install binary ---------------------------------------------------

log "installing zig-fuse into $PREFIX"
$SUDO mkdir -p "$PREFIX"
$SUDO install -m 0755 "$WORK/$BINARY" "$PREFIX/zig-fuse"

log "installed:"
"$PREFIX/zig-fuse" prove 2>/dev/null || true

# --- 5. configure env ----------------------------------------------------

if [ -n "$REGISTRY_URL" ] && [ -z "$TOKEN" ]; then
	if [ "$ASSUME_YES" -eq 1 ]; then
		:
	elif confirm "configure a registry API key for auth? (y = enter your key, N = skip)"; then
		printf 'registry API key (dreg_...): ' >&2
		read -r TOKEN < /dev/tty
	fi
fi

ENV_FILE="/etc/profile.d/voila.sh"
REGISTRY_ENV_LINE=""
if [ -n "$REGISTRY_URL" ]; then
	REGISTRY_ENV_LINE="export VOILA_REGISTRY=\"\${VOILA_REGISTRY:-$REGISTRY_URL}\""
fi
TOKEN_ENV_LINE=""
if [ -n "$TOKEN" ]; then
	TOKEN_ENV_LINE="export VOILA_REGISTRY_TOKEN=\"\${VOILA_REGISTRY_TOKEN:-$TOKEN}\""
fi

log "configuring CLI env ($ENV_FILE)"
$SUDO tee "$ENV_FILE" >/dev/null <<EOF
# voila Zig CLI environment (managed by install.sh).
export VOILA_ROOT="\${VOILA_ROOT:-/var/lib/voila}"
${REGISTRY_ENV_LINE}
${TOKEN_ENV_LINE}
EOF
$SUDO chmod 0644 "$ENV_FILE"
$SUDO mkdir -p /var/lib/voila

# --- done ----------------------------------------------------------------

printf '\033[1;32m==>\033[0m zig-fuse %s installed to %s/zig-fuse\n\n' "$VERSION" "$PREFIX"
cat <<EOF
Next steps:
  1. Reload your shell env (or: source $ENV_FILE)
  2. Run a container (no sudo for the same user when user_allow_other is set):
       zig-fuse run -root "\$VOILA_ROOT" IMAGE_REF -- /bin/sh -c 'echo hi'
  3. List / manage containers:
       zig-fuse ps -root "\$VOILA_ROOT"
       zig-fuse logs -root "\$VOILA_ROOT" <name>

Docs: https://github.com/${REPO}/blob/main/poc/zig-fuse/README.md
EOF
