# Install voila

This guide covers installing the `voila` binaries and connecting them to the
hosted cloud registry at `https://registry.voila.build`, which requires an
account and an API key.

The **`voila-registry` binary** in this repo is a **local**, single-root HTTP
server for dev (`VOILA_ROOT`, no Postgres). The **hosted** multi-tenant
registry (web UI, orgs, API keys) runs at **registry.voila.build** — that is
what `VOILA_REGISTRY`, `voila login`, and `install.sh` target by default.

Until DNS for `registry.voila.build` is live, point at the Railway deployment
instead:

```bash
export VOILA_REGISTRY=https://drift-registry-production.up.railway.app/registry
# or: voila login https://drift-registry-production.up.railway.app/registry
```

If you only want the binaries (no remote registry), the **Install the binaries**
section is all you need — the registry + auth sections are only required to
`voila push`/`voila pull` against the hosted service.

---

## 1. Install the binaries

### One-shot installer (Linux)

On a Linux host (voilad + `voila run` are Linux-only — the runtime uses runc,
and mounts the rootfs via EROFS+NBD by default, falling back to FUSE when the
host lacks EROFS support), the quickest path is the installer script, which
downloads the latest release, verifies the SHA256, installs `voila` + `voilad` +
`voila-registry` into `/usr/local/bin`, and configures the CLI env:

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sudo bash
```

When run from a terminal, the installer **prompts you to install any missing
prerequisites** (e.g. `runc`) via your distro's package manager, and then
**asks whether you want to configure a registry API key** for auth — enter it
to enable push/private-image access, or decline to bypass (public reads still
work). For a fully non-interactive install, pass the flags below (needed when
piping via `curl | sudo bash`).

Useful flags (see `install.sh --help`):

- `--with-systemd` — also install + enable a `voilad` systemd unit.
- `--prefix <dir>` — install elsewhere (default `/usr/local/bin`).
- `--version <tag>` — pin a specific release instead of latest.
- `--install-prereqs` — install missing `runc` via the distro package manager
  (apt-get / dnf / yum / zypper).
- `--install-fuse` — also install `fuse3` + enable `user_allow_other`, for hosts
  that need the FUSE fallback backend (the default is EROFS+NBD).
- `--registry <url>` / `--registry ""` — set or clear the default registry
  (the installer writes it into `/etc/profile.d/voila.sh`).
- `--token <key>` — configure a registry API key (`dreg_...`) non-interactively
  (writes `VOILA_REGISTRY_TOKEN` into the shell env + daemon config). Omit it
  to be prompted, or decline to skip auth.

### Manual install (Linux or macOS)

The `voila` client ships for both linux and darwin; `voilad` and
`voila-registry` are linux-only. Download the matching tarball from the
[latest release](https://github.com/voilabuild/voila/releases/latest),
verify it, and extract:

```bash
VERSION=v0.1.0                       # replace with the latest tag
OS=linux   ARCH=amd64                # darwin / arm64 also work
curl -fsSL -o voila.tar.gz \
  "https://github.com/voilabuild/voila/releases/download/${VERSION}/voila_${VERSION}_${OS}_${ARCH}.tar.gz"
curl -fsSL -o checksums.txt \
  "https://github.com/voilabuild/voila/releases/download/${VERSION}/checksums.txt"
sha256sum -c --ignore-missing checksums.txt
sudo tar -xzf voila.tar.gz -C /usr/local/bin
voila -version
```

Verify the install:

```bash
voila -version
voilad -version        # linux only
voila-registry -version
```

---

## 2. Create your registry account

The hosted registry has a web UI where you sign up with an **org path** — the
namespace your image refs live under (`<org>/<image>:<tag>`).

1. Open <https://registry.voila.build/signup>.
2. Enter an **email**, a **password**, and an **org path** (e.g. your username
   or team name). The org path is your namespace — you can only push to orgs
   you own.
3. Click **Create account**.

---

## 3. Create an API key

1. Log in at <https://registry.voila.build/login>.
2. Open the **Keys** page (nav bar).
3. Create a key and copy it — it looks like `dreg_...`. This is the bearer
   token the CLI sends as `Authorization: Bearer dreg_...`.

---

## 4. Configure the CLI

The recommended path is `voila login` (saves URL + API key to
`~/.config/voila/credentials`, mode `0600`):

```bash
voila login
# Registry URL [https://registry.voila.build/registry]:
# API key: (hidden)
```

You can pass the registry URL on the command line; the default is the hosted
registry above. After login, push and pull work without exporting env vars:

```bash
voila push <org>/<image>:<tag>
```

Run `voila logout` to remove the saved credentials.

Alternatively, set environment variables (they override the login file):

- `VOILA_REGISTRY` — the registry base URL. The hosted registry serves the
  wire protocol under the `/registry` path prefix (the management UI lives at
  the root), so use the full base:
  ```bash
  export VOILA_REGISTRY=https://registry.voila.build/registry
  ```
- `VOILA_REGISTRY_TOKEN` — your API key. Keep it in the environment, not the
  shell history:
  ```bash
  export VOILA_REGISTRY_TOKEN=dreg_...
  ```

If you installed via `install.sh` with a registry URL, it may also add
`VOILA_REGISTRY` to `/etc/profile.d/voila.sh` and your shell rc — env vars win
over `voila login` when both are set.

### The daemon (voilad)

`voilad` lazy-fetches chunks + manifests on demand when it mounts an image.
For **public images** it needs **no token** — chunk reads and public manifest
reads are anonymous on the hosted registry (chunks are capability-by-hash).

The CLI hands registry credentials to `voilad` automatically: before `voila
run`/`push`/`pull`, it writes `<root>/registry.creds` and calls `SetRegistry`
on the worker socket. You configure `VOILA_REGISTRY` + `VOILA_REGISTRY_TOKEN`
in your user shell only — do **not** put the token in `voilad`'s environment
(the `sudo voilad` footgun).

For a systemd install, set only the registry URL (no token):

```bash
sudo tee -a /etc/default/voilad >/dev/null <<'EOF'
VOILA_REGISTRY=https://registry.voila.build/registry
EOF
sudo systemctl restart voilad
```

Run any `voila push`/`pull`/`run` once from a shell that has your API key;
`voilad` picks up the handed-off creds for private images.

---

## 5. Use it

Image refs are org-namespaced: `<org>/<image>:<tag>`.

```bash
# pull a public image (no token needed for reads)
voila pull <org>/<image>:<tag>

# push an image you've imported (needs your API key + ownership of <org>)
voila import python:3.13
voila push <org>/python:3.13
```

On Linux, if EROFS+NBD is unavailable, set `VOILA_MOUNT_BACKEND=fuse` before
starting `voilad` so `voila run` can mount images via FUSE.

Auth rules to keep in mind:

- **Push** always requires your API key, and you can only push to orgs you own
  (the registry returns `403` otherwise).
- **Public image reads** (manifest + chunks) are anonymous.
- **Private manifests** return `404` to non-owners (so existence isn't leaked);
  reading them requires the owning org's key.
- **Chunk reads** are anonymous by design (capability-by-hash), so a CDN can
  cache them — the token is never needed for the read path.

---

## Troubleshooting

- **`voila push` fails with 401** — your API key is missing or wrong. Run
  `voila login` again or re-check the key on the Keys page.
- **`voila push` fails with 403** — you're pushing to an org you don't own.
  Use your own org path.
- **`voilad` can't fetch a private image** — run `voila login`, then
  `voila pull` or `voila run` once so the CLI hands creds off to the daemon
  (see the daemon section above). Check `<root>/registry.creds` exists and
  `voilad` has `VOILA_REGISTRY` (or `-registry`) for the base URL.
- **`voila pull` of a private image 404s** — either the image is private and
  you're not the owner, or the ref is wrong.
