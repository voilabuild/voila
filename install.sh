#!/bin/bash
# install.sh — one-shot installer for the voila Zig CLI on Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/voilabuild/voila/main/install.sh | sh
#   curl -fsSL ... | sudo sh   # only needed for /usr/local/bin and /etc/fuse.conf
#
# Flags:
#   --version <tag>      Pin to a release tag (default: latest).
#   --prefix <dir>       Install directory (default: /usr/local/bin if writable, else ~/.local/bin).
#   --registry <url>     Default registry base (optional; login via `voila login` is preferred).
#   --token <key>        Registry API key (optional; prefer `voila login`).
#   --install-prereqs    Install missing fuse3 via the distro package manager.
#   --yes                Assume yes to prompts (non-interactive).

set -euo pipefail

REPO="voilabuild/voila"
PREFIX=""
VERSION=""
INSTALL_PREREQS=0
ASSUME_YES=0
TOKEN=""
REGISTRY_URL="https://registry.voila.build/registry"

usage() {
	cat <<'EOF'
install.sh — install the voila Zig CLI (static musl binary) on Linux.

  curl -fsSL https://raw.githubusercontent.com/voilabuild/voila/main/install.sh | sh

Flags:
  --version <tag>      Pin to a release tag (default: latest).
  --prefix <dir>       Install directory (default: /usr/local/bin or ~/.local/bin).
  --registry <url>     Remote registry base URL (default: hosted drift registry).
  --token <key>        Registry API key (dreg_...); prefer `voila login` after install.
  --install-prereqs    Install missing fuse3 via apt-get/dnf/yum/zypper.
  --yes                Non-interactive (accept prompts).
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

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: '$1'"
}

curl_auth() {
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		curl -H "Authorization: Bearer ${GITHUB_TOKEN}" "$@"
	elif [ -n "${GH_TOKEN:-}" ]; then
		curl -H "Authorization: Bearer ${GH_TOKEN}" "$@"
	elif [ -n "${FORGEJO_TOKEN:-}" ]; then
		curl -H "Authorization: Bearer ${FORGEJO_TOKEN}" "$@"
	else
		curl "$@"
	fi
}

confirm() {
	[ "$ASSUME_YES" -eq 1 ] && return 0
	local prompt="$1 [y/N] " reply
	if [ -t 0 ]; then
		read -r -p "$prompt" reply
	else
		if ! read -r -p "$prompt" reply < /dev/tty; then
			die "no terminal for prompts; use --yes or --install-prereqs"
		fi
	fi
	[[ "$reply" =~ ^[Yy]$ ]]
}

log "checking prerequisites"

case "$(uname -s)" in
	Linux) : ;;
	*) die "Linux only (detected $(uname -s))" ;;
esac

case "$(uname -m)" in
	x86_64|amd64) ARCH=amd64 ;;
	aarch64|arm64) ARCH=arm64 ;;
	*) die "unsupported architecture: $(uname -m)" ;;
esac

need_cmd curl
need_cmd sha256sum

if [ -z "$PREFIX" ]; then
	if [ -w /usr/local/bin ] 2>/dev/null || [ "$(id -u)" -eq 0 ]; then
		PREFIX="/usr/local/bin"
	else
		PREFIX="${HOME}/.local/bin"
	fi
fi

if [ -w "$PREFIX" ] || [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	need_cmd sudo
	SUDO="sudo"
fi

check_runtime_prereqs() {
	local missing=0
	[ -e /dev/fuse ] || { warn "/dev/fuse not found"; missing=1; }
	command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || { warn "fuse3 not found"; missing=1; }
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
	[ -n "$mgr" ] || die "no supported package manager; install fuse3 manually"
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
		pkg_install fuse3 || warn "continuing without fuse3 (install failed or no sudo)"
	elif confirm "install missing prerequisite (fuse3)?"; then
		pkg_install fuse3 || warn "continuing without fuse3"
	else
		warn "continuing without fuse3"
	fi
fi

fuse_conf_has_user_allow_other() {
	[ -f /etc/fuse.conf ] && grep -qE '^[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf
}

ensure_user_allow_other() {
	if fuse_conf_has_user_allow_other; then
		return 0
	fi
	if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
		warn "/etc/fuse.conf lacks user_allow_other — re-run with sudo or add the line manually"
		return 0
	fi
	log "configuring /etc/fuse.conf (user_allow_other)"
	if [ ! -f /etc/fuse.conf ]; then
		echo 'user_allow_other' | $SUDO tee /etc/fuse.conf >/dev/null
		return 0
	fi
	if ! fuse_conf_has_user_allow_other; then
		if grep -qE '^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$' /etc/fuse.conf; then
			$SUDO sed -i 's/^[[:space:]]*#[[:space:]]*user_allow_other[[:space:]]*$/user_allow_other/' /etc/fuse.conf
		fi
	fi
	if ! fuse_conf_has_user_allow_other; then
		echo 'user_allow_other' | $SUDO tee -a /etc/fuse.conf >/dev/null
	fi
}

ensure_user_allow_other

if [ -z "$VERSION" ]; then
	log "resolving latest release tag"
	VERSION="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
		| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
	[ -n "$VERSION" ] || die "could not resolve latest release tag"
fi
log "using release $VERSION (linux/$ARCH)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BINARY="voila_${VERSION}_linux_${ARCH}"
LEGACY_BINARY="zig-fuse_${VERSION}_linux_${ARCH}"

fetch_asset() {
	local name="$1" out="$2"
	local simple="https://github.com/${REPO}/releases/download/${VERSION}/${name}"
	if curl_auth -fsSL -o "$out" "$simple" 2>/dev/null; then
		return 0
	fi
	die "download failed: $simple"
}

log "downloading $BINARY"
if ! fetch_asset "$BINARY" "$WORK/$BINARY" 2>/dev/null; then
	log "falling back to legacy asset name $LEGACY_BINARY"
	fetch_asset "$LEGACY_BINARY" "$WORK/voila"
else
	cp "$WORK/$BINARY" "$WORK/voila"
fi

if curl_auth -fsSL -o "$WORK/voila-checksums.txt" \
	"https://github.com/${REPO}/releases/download/${VERSION}/voila-checksums.txt" 2>/dev/null; then
	CHECKSUMS="$WORK/voila-checksums.txt"
elif curl_auth -fsSL -o "$WORK/zig-fuse-checksums.txt" \
	"https://github.com/${REPO}/releases/download/${VERSION}/zig-fuse-checksums.txt" 2>/dev/null; then
	CHECKSUMS="$WORK/zig-fuse-checksums.txt"
else
	die "could not download checksums file"
fi

log "verifying sha256"
if ( cd "$WORK" && grep -F "$BINARY" "$CHECKSUMS" | sha256sum -c ); then
	:
elif ( cd "$WORK" && grep -F "$LEGACY_BINARY" "$CHECKSUMS" | sha256sum -c ); then
	:
else
	die "checksum verification failed"
fi

log "installing voila into $PREFIX"
$SUDO mkdir -p "$PREFIX"
$SUDO install -m 0755 "$WORK/voila" "$PREFIX/voila"
if [ "$PREFIX/voila" != "$PREFIX/zig-fuse" ]; then
	$SUDO ln -sf voila "$PREFIX/zig-fuse"
fi

case "$PREFIX" in
	/usr/local/bin|/usr/bin) VOILA_ROOT="/var/lib/voila" ;;
	*) VOILA_ROOT="${HOME}/.local/share/voila" ;;
esac

USER_ENV="${HOME}/.config/voila/env.sh"
mkdir -p "$(dirname "$USER_ENV")"
cat >"$USER_ENV" <<EOF
# voila environment (install.sh)
export VOILA_ROOT="\${VOILA_ROOT:-$VOILA_ROOT}"
EOF
if [ -n "$REGISTRY_URL" ]; then
	echo "export VOILA_REGISTRY=\"\${VOILA_REGISTRY:-$REGISTRY_URL}\"" >>"$USER_ENV"
fi
if [ -n "$TOKEN" ]; then
	echo "export VOILA_REGISTRY_TOKEN=\"\${VOILA_REGISTRY_TOKEN:-$TOKEN}\"" >>"$USER_ENV"
fi

if [ -w /etc/profile.d ] 2>/dev/null || [ -n "$SUDO" ]; then
	$SUDO mkdir -p /etc/profile.d
	$SUDO tee /etc/profile.d/voila.sh >/dev/null <<EOF
# voila Zig CLI (system-wide defaults)
export VOILA_ROOT="\${VOILA_ROOT:-/var/lib/voila}"
EOF
fi

case ":$PATH:" in
	*":$PREFIX:"*) ;;
	*) warn "add $PREFIX to your PATH (e.g. export PATH=\"$PREFIX:\$PATH\")" ;;
esac

maybe_install_apparmor_profile() {
	if [ ! -d /sys/kernel/security/apparmor ]; then
		return 0
	fi
	restrict="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
	if [ "$restrict" != "1" ]; then
		return 0
	fi
	if ! command -v apparmor_parser >/dev/null 2>&1; then
		warn "AppArmor restricts user namespaces; install apparmor-utils for voila -it/-v/-p"
		return 0
	fi
	VOILA_BIN="$PREFIX/voila"
	log "installing AppArmor profile for user namespaces (Ubuntu 24.04+)"
	$SUDO tee /etc/apparmor.d/voila >/dev/null <<EOF
abi <abi/4.0>,
include <tunables/global>

profile voila $VOILA_BIN flags=(unconfined) {
	userns,
	include if exists <local/voila>
}
EOF
	if [ "$VOILA_BIN" != "${HOME}/.local/bin/voila" ] && [ -x "${HOME}/.local/bin/voila" ]; then
		$SUDO tee -a /etc/apparmor.d/voila >/dev/null <<EOF

profile voila_home ${HOME}/.local/bin/voila flags=(unconfined) {
	userns,
	include if exists <local/voila>
}
EOF
	fi
	if $SUDO apparmor_parser -r /etc/apparmor.d/voila 2>/dev/null; then
		log "loaded AppArmor profile voila (unprivileged userns allowed for voila binary)"
	else
		warn "could not load AppArmor profile; you may need: sudo apparmor_parser -r /etc/apparmor.d/voila"
	fi
}

maybe_install_apparmor_profile

printf '\033[1;32m==>\033[0m voila %s installed to %s/voila\n' "$VERSION" "$PREFIX"
cat <<EOF

Next steps:
  1. source $USER_ENV   # or add it to your shell rc
  2. voila login        # save drift URL, org, and API key (~/.config/voila/credentials)
  3. voila pull nginx     # imports from Docker Hub on first pull when needed
  4. voila run --rm alpine echo hi

Docs: https://github.com/${REPO}/blob/main/doc/INSTALL.md
EOF
