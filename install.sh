#!/bin/bash
# install.sh — one-shot installer for voila prebuilt release binaries (Linux).
#
# What it does:
#   1. Verifies prerequisites (OS, arch, curl/tar/sha256sum, root/sudo, runc;
#      FUSE bits are soft warnings — only needed for the FUSE fallback backend).
#   2. Resolves the latest `v*` release tag from GitHub (or pins to --version).
#   3. Downloads the per-arch Linux tarball + checksums.txt and verifies the
#      SHA256 before extracting anything.
#   4. Installs voila, voilad and voila-registry into --prefix (default
#      /usr/local/bin).
#   5. Configures the CLI: writes /etc/profile.d/voila.sh with the default
#      VOILA_ROOT / VOILA_SOCKET / VOILA_REGISTRY env vars so every shell gets
#      a consistent client config.
#   6. Optionally installs + enables a voilad systemd unit (--with-systemd).
#
# Linux only: voilad (the worker daemon) mounts the rootfs via EROFS+NBD by
# default (falling back to FUSE when the host lacks EROFS support) and runs
# containers via runc; the runtime is Linux-only by design (see .goreleaser.yaml).
# The `voila` client alone ships for darwin too, but this installer targets a
# Linux host that wants the full daemon + client stack.
#
# Usage:
#   curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sudo bash
#   # or, from a clone:
#   sudo ./install.sh [--version v0.1.0] [--prefix /usr/local/bin] \
#       [--with-systemd] [--install-prereqs] [--yes]
#
# Flags:
#   --version <tag>      Pin to a specific release tag (default: latest).
#   --prefix <dir>      Install directory (default: /usr/local/bin).
#   --token <key>       Registry API key (dreg_...) for auth; asks interactively
#                       if omitted, bypass by declining.
#   --with-systemd       Install + enable a voilad systemd unit.
#   --install-prereqs   Install missing runc via the distro package manager
#                       (apt-get / dnf / yum / zypper).
#   --install-fuse      Also install fuse3 + user_allow_other (FUSE fallback only).
#   --yes               Assume yes to prompts (non-interactive).
#   -h, --help          Show this help.

set -euo pipefail

REPO="voilabuild/voila"
PREFIX="/usr/local/bin"
VERSION=""
WITH_SYSTEMD=0
INSTALL_PREREQS=0
INSTALL_FUSE=0
ASSUME_YES=0
# Optional registry API key (dreg_...) for auth against the hosted registry.
# Empty = no auth configured (public reads still work; push/private needs it).
# Set via --token or an interactive prompt; bypass by leaving it empty.
TOKEN=""
# Default remote chunk registry. The daemon lazy-fetches chunks from here on a
# miss, and `voila push`/`pull` move image manifests through it. Override with
# --registry <url>; clear it with --registry "" to run fully offline.
# The hosted registry serves the wire protocol under the /registry path prefix
# (the management UI lives at the root), so the base includes it.
REGISTRY_URL="https://registry.voila.build/registry"

usage() {
	sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,/^$/p' || true
	cat <<'EOF'

Flags:
  --version <tag>      Pin to a specific release tag (default: latest).
  --prefix <dir>       Install directory (default: /usr/local/bin).
  --registry <url>     Remote chunk registry the daemon lazy-fetches from
                      (default: https://registry.voila.build/registry;
                      pass "" to run offline).
  --token <key>       Registry API key (dreg_...) to configure for auth
                      (push/private images). If omitted, the installer asks
                      interactively; you can bypass by declining.
  --with-systemd       Install + enable a voilad systemd unit.
  --install-prereqs    Install missing runc via the distro package manager
                      (apt-get / dnf / yum / zypper).
  --install-fuse       Also install fuse3 + enable user_allow_other (only needed
                      for the FUSE fallback backend; the default is EROFS+NBD).
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
		--with-systemd)    WITH_SYSTEMD=1; shift ;;
		--install-prereqs) INSTALL_PREREQS=1; shift ;;
		--install-fuse)    INSTALL_FUSE=1; shift ;;
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

# curl with optional auth. The repo may be private (or a private fork); in that
# case the unauthenticated /releases/latest API call and the releases/download/*
# asset URLs both 404. If GITHUB_TOKEN / GH_TOKEN / FORGEJO_TOKEN is set,
# send it as a Bearer header so tag resolution + downloads work against private
# repos. Public repos keep working with no token. (We do NOT print the token.)
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
		# stdin isn't a terminal (e.g. `curl ... | sudo bash`), so read the
		# answer from the controlling tty instead — this lets piped installs
		# still prompt. If there's no tty at all (cron, CI), fail clearly.
		if ! read -r -p "$prompt" reply < /dev/tty; then
			die "missing a required prerequisite and no terminal is available (piped install). Re-run with --install-prereqs or --yes, or from a terminal."
		fi
	fi
	[[ "$reply" =~ ^[Yy]$ ]]
}

# --- 1. prerequisite checks ----------------------------------------------

log "checking prerequisites"

# OS: must be Linux. voilad is Linux-only (FUSE + runc); the daemon is the
# whole point of this installer, so we fail fast anywhere else.
case "$(uname -s)" in
	Linux) : ;;
	*) die "this installer is Linux-only (detected $(uname -s)). voilad needs runc + the Linux mount backend (EROFS+NBD, or FUSE fallback)." ;;
esac

# Arch: goreleaser publishes linux_amd64 + linux_arm64. Map the kernel's
# reported machine string onto goreleaser's arch names.
case "$(uname -m)" in
	x86_64|amd64) ARCH=amd64 ;;
	aarch64|arm64) ARCH=arm64 ;;
	*) die "unsupported architecture: $(uname -m) (only amd64 / arm64 are released)" ;;
esac

need_cmd curl
need_cmd tar
need_cmd sha256sum
need_cmd uname

# Installing into a system prefix needs root (the default /usr/local/bin is
# root-owned). Allow a non-root --prefix to a writable dir for throwaway setups.
if [ -w "$PREFIX" ] || [ "$(id -u)" -eq 0 ]; then
	SUDO=""
else
	need_cmd sudo
	SUDO="sudo"
	if ! $SUDO -n true 2>/dev/null && [ "$ASSUME_YES" -ne 1 ]; then
		: # sudo will prompt interactively when we actually use it
	fi
fi

# Runtime prereqs the daemon + `voila run` actually need at use time. We report
# them up front so the user sees the full picture before anything is installed.
#
# The default mount backend is EROFS+NBD (auto-selected when the kernel is
# 5.15+ with the erofs/nbd modules and a free /dev/nbd*); FUSE is only the
# fallback when EROFS isn't available. So runc is a hard requirement (needed
# for `voila run` regardless of backend), while the FUSE bits are soft warnings
# — only relevant on hosts that fall back to FUSE.
check_runtime_prereqs() {
	local missing=0
	if ! command -v runc >/dev/null 2>&1; then
		warn "runc not found — 'voila run' needs it for namespacing/cgroups."
		missing=1
	fi
	if [ ! -e /dev/fuse ]; then
		warn "/dev/fuse not found — only needed for the FUSE fallback backend (default is EROFS+NBD)."
	fi
	if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
		warn "fuse3 not found (no fusermount3/fusermount) — only needed for the FUSE fallback backend."
	fi
	if [ -f /etc/fuse.conf ] && ! grep -q '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		warn "/etc/fuse.conf is missing 'user_allow_other' — only needed for the FUSE fallback backend."
	fi
	return $missing
}

# --- package manager helpers ----------------------------------------------

# detect_pkgmgr prints the distro's package manager (apt-get / dnf / yum /
# zypper) or empty if none is supported. dnf is preferred over yum (dnf is the
# modern yum on Fedora/RHEL).
detect_pkgmgr() {
	if command -v apt-get >/dev/null 2>&1; then
		echo "apt-get"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v yum >/dev/null 2>&1; then
		echo "yum"
	elif command -v zypper >/dev/null 2>&1; then
		echo "zypper"
	else
		echo ""
	fi
}

# pkg_install <pkg...> — installs the given packages with the detected manager.
pkg_install() {
	local mgr
	mgr="$(detect_pkgmgr)"
	[ -n "$mgr" ] || die "no supported package manager found (apt-get, dnf/yum, or zypper). Install '$*' manually and re-run."
	log "installing via $mgr: $*"
	case "$mgr" in
		apt-get)
			$SUDO apt-get update -y
			DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$@"
			;;
		dnf|yum)
			$SUDO "$mgr" install -y "$@"
			;;
		zypper)
			$SUDO zypper --non-interactive install "$@"
			;;
	esac
}

if ! check_runtime_prereqs; then
	if [ "$INSTALL_PREREQS" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
		# Flag or --yes: install without prompting.
		log "installing runtime prerequisite (runc)"
		pkg_install runc
		log "re-checking prerequisites"
		check_runtime_prereqs || warn "some runtime prerequisites still missing — see messages above"
	else
		# Ask before installing. confirm() reads from the controlling tty, so
		# this works even for `curl ... | sudo bash`; it dies with a clear
		# message only when no terminal is available at all.
		if confirm "install missing prerequisites (runc) via your distro's package manager?"; then
			pkg_install runc
			log "re-checking prerequisites"
			check_runtime_prereqs || warn "some runtime prerequisites still missing — see messages above"
		else
			warn "skipping prerequisite install; runc may be missing at use time."
			confirm "continue anyway?" || die "aborted by user"
		fi
	fi
fi

# FUSE fallback backend is opt-in: only install it when explicitly requested.
if [ "$INSTALL_FUSE" -eq 1 ]; then
	log "installing FUSE fallback backend (fuse3)"
	pkg_install fuse3
	if [ -f /etc/fuse.conf ] && ! grep -q '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
		$SUDO sed -i 's/^# *user_allow_other/user_allow_other/' /etc/fuse.conf || \
			echo 'user_allow_other' | $SUDO tee -a /etc/fuse.conf >/dev/null
	fi
fi

# --- 2. resolve the latest tag -------------------------------------------

if [ -z "$VERSION" ]; then
	log "resolving latest release tag from github.com/$REPO"
	# /releases/latest excludes drafts + prereleases; .tag_name is the `v*` tag.
	VERSION="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
		| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -n1)"
	# Fallback: if there is no stable release yet (only prereleases), /releases/latest
	# 404s. List releases newest-first and take the top tag (includes prereleases).
	if [ -z "$VERSION" ]; then
		VERSION="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=1" \
			| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
			| head -n1)"
	fi
	[ -n "$VERSION" ] || die "could not resolve latest release tag from GitHub API"
fi
log "using release $VERSION (linux/$ARCH)"

# --- 3. download + verify checksum ---------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TARBALL="voila_${VERSION}_linux_${ARCH}.tar.gz"

# fetch_asset <filename> <output_path>
# Public repo: the releases/download/<tag>/<asset> shortcut works with no auth.
# Private repo: that shortcut 404s even with a Bearer token — the only path that
# works is the API asset endpoint with Accept: application/octet-stream. So try
# the simple URL first; on failure, if a token is available, resolve the asset's
# API url from /releases/tags/<tag> and download via the API endpoint.
fetch_asset() {
	local name="$1" out="$2"
	local simple="https://github.com/${REPO}/releases/download/${VERSION}/${name}"
	# Failure here is expected for private repos; silence curl's stderr so the
	# fallback log line below is the only signal. The fallback reports real errors.
	if curl_auth -fsSL -o "$out" "$simple" 2>/dev/null; then
		return 0
	fi
	[ "${#CURL_AUTH[@]}" -gt 0 ] || die "download failed: $simple"
	log "private repo: resolving $name via GitHub API"
	local meta asset_url
	meta="$(curl_auth -fsSL "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" \
		|| die "could not fetch release metadata from GitHub API"
	# The asset object's "url" field (the API endpoint) precedes its "name"
	# field, so capture the most recent "url": then match the wanted "name":.
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

log "downloading $TARBALL"
fetch_asset "$TARBALL" "$WORK/$TARBALL"
fetch_asset "checksums.txt" "$WORK/checksums.txt"

log "verifying sha256"
# checksums.txt covers all four platform tarballs; narrow to the one we fetched.
( cd "$WORK" && sha256sum -c --ignore-missing checksums.txt ) \
	|| die "checksum verification failed — the download may be corrupt or tampered with"

# --- 4. install binaries -------------------------------------------------

log "installing binaries into $PREFIX"
$SUDO mkdir -p "$PREFIX"
# Archive ships binaries at the root (no wrapping dir), so extract straight
# into the prefix. voila + voilad + voila-registry all land in one shot.
$SUDO tar -xzf "$WORK/$TARBALL" -C "$PREFIX"
$SUDO chmod 0755 "$PREFIX/voila" "$PREFIX/voilad" "$PREFIX/voila-registry"

log "installed:"
"$PREFIX/voila" -version || true
"$PREFIX/voilad" -version || true
"$PREFIX/voila-registry" -version || true

# --- 5. configure the CLI ------------------------------------------------

# Optional registry auth: if a registry is configured and no --token was
# given, offer to enter an API key. confirm() reads from the controlling tty
# (so piped installs still work); declining or --yes skips auth entirely.
if [ -n "$REGISTRY_URL" ] && [ -z "$TOKEN" ]; then
	if [ "$ASSUME_YES" -eq 1 ]; then
		: # --yes: skip auth config
	elif confirm "configure a registry API key for auth? (y = enter your key, N = skip)"; then
		printf 'registry API key (dreg_...): ' >&2
		read -r TOKEN < /dev/tty
	fi
fi

# Write /etc/profile.d/voila.sh so every login shell gets the same client
# defaults the binaries already assume (VOILA_ROOT, VOILA_SOCKET) plus a
# commented VOILA_REGISTRY the user can uncomment to point at a registry.
# This is the "configure the CLI" step: it makes the env-var contract explicit
# and discoverable instead of relying on tribal knowledge of the defaults.
ENV_FILE="/etc/profile.d/voila.sh"
log "configuring CLI env ($ENV_FILE)"
# Build the VOILA_REGISTRY export line only when a registry is configured, so
# an offline install (--registry "") exports nothing rather than an empty var.
REGISTRY_ENV_LINE=""
if [ -n "$REGISTRY_URL" ]; then
	REGISTRY_ENV_LINE="export VOILA_REGISTRY=\"\${VOILA_REGISTRY:-$REGISTRY_URL}\""
fi
# The API key export line is only written when a token was provided, so an
# auth-less install exports nothing rather than an empty var.
TOKEN_ENV_LINE=""
if [ -n "$TOKEN" ]; then
	TOKEN_ENV_LINE="export VOILA_REGISTRY_TOKEN=\"\${VOILA_REGISTRY_TOKEN:-$TOKEN}\""
fi
$SUDO tee "$ENV_FILE" >/dev/null <<EOF
# voila CLI / daemon environment (managed by install.sh).
# Data root + worker socket defaults — match the binary defaults so the CLI
# and voilad agree even if you only set one of them.
export VOILA_ROOT="\${VOILA_ROOT:-/var/lib/voila}"
export VOILA_SOCKET="\${VOILA_SOCKET:-/var/run/voila.sock}"
# Remote chunk registry: the daemon lazy-fetches chunks from here on a miss,
# and 'voila push'/'pull' move image manifests through it. Override per-shell
# by exporting VOILA_REGISTRY before sourcing this file (or edit this line).
${REGISTRY_ENV_LINE}
# Registry API key (bearer) sent as 'Authorization: Bearer <key>' on push and
# private-image reads. Override per-shell by exporting VOILA_REGISTRY_TOKEN.
${TOKEN_ENV_LINE}
EOF
$SUDO chmod 0644 "$ENV_FILE"

# /etc/profile.d is only sourced by LOGIN shells (and bash at that) — not by
# every new interactive shell, and not by zsh. So also append the same exports
# to the invoking user's ~/.bashrc and ~/.zshrc so the CLI env is present in
# every new shell, not just login bash.
configure_user_shell() {
	local user=""
	for _c in "${SUDO_USER:-}" "$(logname 2>/dev/null)" "${USER:-}" "${LOGNAME:-}"; do
		[ -n "$_c" ] || continue
		[ "$_c" != "root" ] || continue
		id "$_c" >/dev/null 2>&1 || continue
		user="$_c"; break
	done
	[ -n "$user" ] || return 0
	local home
	home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
	[ -n "$home" ] || return 0

	# Build the export block; skip if there's nothing to configure.
	local lines=""
	[ -n "$REGISTRY_URL" ] && lines="$lines\nexport VOILA_REGISTRY=\"\${VOILA_REGISTRY:-$REGISTRY_URL}\""
	[ -n "$TOKEN" ] && lines="$lines\nexport VOILA_REGISTRY_TOKEN=\"\${VOILA_REGISTRY_TOKEN:-$TOKEN}\""
	[ -n "$lines" ] || return 0

	for rc in "$home/.bashrc" "$home/.zshrc"; do
		[ -f "$rc" ] || continue
		if ! grep -q 'VOILA_REGISTRY' "$rc" 2>/dev/null; then
			log "adding voila env to $rc"
			$SUDO tee -a "$rc" >/dev/null <<EOF

# voila CLI / daemon env (added by install.sh).
$(printf '%b' "$lines")
EOF
		fi
	done
}
configure_user_shell

# Make sure the data root + socket dir exist so the daemon can start cold.
$SUDO mkdir -p /var/lib/voila "$(dirname /var/run/voila.sock)"

# --- 6. optional systemd unit -------------------------------------------

if [ "$WITH_SYSTEMD" -eq 1 ]; then
	if ! command -v systemctl >/dev/null 2>&1; then
		warn "--with-systemd given but systemctl not found; skipping unit install"
	else
		# The daemon runs as root (it needs /dev/fuse + CAP_SYS_ADMIN for the
		# FUSE rootfs mount + runc), but the CLI is meant to be driven by
		# unprivileged users. voilad locks the worker socket to 0600 by
		# default, which would block everyone but root — so we create a
		# `voila` system group, tell voilad (via VOILA_SOCKET_GROUP/MODE) to
		# make the socket root:voila 0660, and add the invoking user to the
		# group so they can run `voila` without sudo.
		if ! getent group voila >/dev/null 2>&1; then
			log "creating voila system group"
			$SUDO groupadd --system voila
		fi

		# Detect the invoking (non-root) user. `sudo ./install.sh` sets
		# SUDO_USER; a root shell (`sudo -i` / `su -`) does not, so fall back
		# to logname (login name on the controlling tty), then $USER/$LOGNAME.
		# We never auto-add root — being in `voila` is root-equivalent, so it
		# would be pointless.
		INVOKER=""
		for _c in "${SUDO_USER:-}" "$(logname 2>/dev/null)" "${USER:-}" "${LOGNAME:-}"; do
			[ -n "$_c" ] || continue
			[ "$_c" != "root" ] || continue
			id "$_c" >/dev/null 2>&1 || continue
			INVOKER="$_c"; break
		done

		ADDGROUP_NOTE=0
		ADDGROUP_SELF=0
		if [ -n "$INVOKER" ]; then
			if id -nG "$INVOKER" 2>/dev/null | tr ' ' '\n' | grep -qx voila; then
				log "$INVOKER is already in the voila group"
			else
				log "adding $INVOKER to the voila group (needed to use the CLI without sudo)"
				if command -v usermod >/dev/null 2>&1; then
					$SUDO usermod -aG voila "$INVOKER" && ADDGROUP_NOTE=1
				elif command -v gpasswd >/dev/null 2>&1; then
					$SUDO gpasswd -a "$INVOKER" voila && ADDGROUP_NOTE=1
				else
					warn "neither usermod nor gpasswd found — could not auto-add $INVOKER"
					ADDGROUP_SELF=1
				fi
			fi
		else
			ADDGROUP_SELF=1
		fi
		if [ "$ADDGROUP_SELF" -eq 1 ]; then
			warn "could not auto-detect the invoking user (running as root with no SUDO_USER)."
			warn "to use the CLI without sudo, add yourself to the voila group, then log out + back in:"
			warn "    sudo usermod -aG voila <your-user>      # or: sudo gpasswd -a <your-user> voila"
		fi

		log "installing voilad systemd unit"
		# Only set VOILA_REGISTRY in the unit when a registry is configured, so
		# an offline install (--registry "") doesn't pin an empty value.
		REGISTRY_ENV=""
		if [ -n "$REGISTRY_URL" ]; then
			REGISTRY_ENV="Environment=VOILA_REGISTRY=$REGISTRY_URL"
		fi
		# Token stays CLI-only; voilad receives it via registry.creds handoff.
		UNIT=/etc/systemd/system/voilad.service
		$SUDO tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=voila worker daemon
Documentation=https://github.com/${REPO}
After=network-online.target

[Service]
Type=simple
Environment=VOILA_ROOT=/var/lib/voila
Environment=VOILA_SOCKET=/var/run/voila.sock
Environment=VOILA_SOCKET_GROUP=voila
Environment=VOILA_SOCKET_MODE=0660
${REGISTRY_ENV}
# Override any of the above here (e.g. VOILA_REGISTRY) — see /etc/default/voilad.
EnvironmentFile=-/etc/default/voilad
ExecStart=$PREFIX/voilad
Restart=on-failure
# voilad mounts the rootfs via EROFS+NBD by default (FUSE fallback) and runs
# containers via runc — all need CAP_SYS_ADMIN; EROFS also needs the nbd device.
AmbientCapabilities=CAP_SYS_ADMIN
DeviceAllow=/dev/fuse rw
DeviceAllow=/dev/nbd* rw

[Install]
WantedBy=multi-user.target
EOF
		$SUDO systemctl daemon-reload
		$SUDO systemctl enable --now voilad.service
		log "voilad enabled and started (systemctl status voilad)"
		if [ "${ADDGROUP_NOTE:-0}" -eq 1 ]; then
			warn "$INVOKER was added to the voila group — log out + back in (or 'newgrp voila') for it to take effect."
		fi
		if [ "${ADDGROUP_SELF:-0}" -eq 1 ]; then
			warn "until you add yourself to the voila group, 'voila' will need sudo (the socket is root:voila 0660)."
		fi
	fi
fi

# --- done ----------------------------------------------------------------

printf '\033[1;32m==>\033[0m voila %s installed to %s\n\n' "$VERSION" "$PREFIX"
cat <<EOF
Next steps:
  1. Reload your shell env (or: source $ENV_FILE)
EOF
if [ "$WITH_SYSTEMD" -eq 1 ]; then
	if [ "${ADDGROUP_NOTE:-0}" -eq 1 ]; then
		echo "     and log out + back in (or 'newgrp voila') so the voila group takes effect"
	elif [ "${ADDGROUP_SELF:-0}" -eq 1 ]; then
		echo "     add yourself to the voila group, then log out + back in:"
		echo "       sudo usermod -aG voila <your-user>   # or: sudo gpasswd -a <your-user> voila"
	else
		echo "     (you're already in the voila group — no group step needed)"
	fi
fi
cat <<EOF
  2. Start the daemon (pick one):
       sudo voilad &                                   # foreground (root-only socket)
       sudo systemctl start voilad                     # --with-systemd (group voila can dial)
  3. Verify group membership (after re-login):
       id -nG | grep -q voila && echo "voila group OK"
  4. Pull + run an image:
       voila import python:3.13
       voila run python:3.13 -- python -c 'print("hi")'
EOF
if [ -n "$REGISTRY_URL" ]; then
	cat <<EOF
  Remote registry (lazy chunk fetch + push/pull): $REGISTRY_URL
       override per-shell:  export VOILA_REGISTRY=<url>
       override the daemon: edit /etc/default/voilad, then 'systemctl restart voilad'
EOF
else
	echo "  Remote registry: none (offline). Set VOILA_REGISTRY to enable lazy fetch / push-pull."
fi
cat <<EOF

Docs: https://github.com/${REPO}#readme
EOF
