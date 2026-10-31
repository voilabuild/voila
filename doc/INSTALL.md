# Install voila

This guide covers installing the `voila` binary and connecting them to the
hosted registry at `https://registry.voila.build`, which
requires an account and an API key.

If you only want the binary (no remote registry), the **Install the binaries**
section is all you need — the registry + auth sections are only required to
`voila push`/`voila pull` against the hosted service.

---

## 1. Install the binary

### One-shot installer (Linux, amd64 or arm64)

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh
```

It downloads the static `voila` binary for your architecture, verifies the
release checksum, and installs it to `/usr/local/bin` when writable (or with
`sudo`), otherwise `~/.local/bin`. With `sudo` it also enables
`user_allow_other` in `/etc/fuse.conf`. On Ubuntu 24.04+ it installs an
AppArmor profile that lets `voila` create unprivileged user namespaces,
which `voila run` and `voila build` need. From a terminal it offers to install
missing prerequisites and to configure a registry API key.

Flags (see `install.sh --help`):

- `--prefix <dir>`: install directory.
- `--version <tag>`: pin a release instead of the latest.
- `--install-prereqs`: install missing `fuse3` via apt-get / dnf / yum / zypper.
- `--registry <url>` / `--registry ""`: set or clear the default registry.
- `--token <key>`: configure a registry API key (`dreg_...`) non-interactively.
- `--yes`: accept prompts.

Optional: install `uidmap` (`newuidmap`/`newgidmap`) and give your user an
`/etc/subuid` / `/etc/subgid` range, so `RUN` steps can switch users and
`chown` (see [CLI.md](CLI.md#building-images)). Install `passt` (the `pasta`
binary) so `voila run` has outbound network; without it the container has
loopback only. `-p` works either way.

### Manual install

Download `voila_<tag>_linux_<arch>` and the checksums file from the
[latest release](https://github.com/voilabuild/voila/releases/latest), verify
it with `sha256sum -c --ignore-missing`, and copy it to a directory on your
`PATH` as `voila`. On Ubuntu 24.04+ you also need the AppArmor profile that
`install.sh` writes to `/etc/apparmor.d/voila`.

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
- **`voila run` fails with a user-namespace or FUSE error** — check that
  `/dev/fuse` exists and, on Ubuntu 24.04+, that the AppArmor profile from
  `install.sh` is loaded (`sudo apparmor_parser -r /etc/apparmor.d/voila`).
  The profile is tied to the installed binary's path.
- **`voila pull` of a private image 404s** — either the image is private and
  you're not the owner, or the ref is wrong.
