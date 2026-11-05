# Changelog

All notable changes to this project are documented here.

## v0.1.0-alpha.5 — 2026-11-05

Fixes from validating alpha.4 against a Docker-user scenario (#166).

### Highlights

- `voila run` with networking no longer waits ~1 s at exit: Ubuntu's pasta AppArmor profile refuses voila's signal, and the run now returns without waiting for pasta (warm `run --rm alpine true`: 1.06 s → 0.05 s)
- `-i` without `-t` keeps stdin a plain pipe: `echo x | voila run -i img cat` and `run -i img sh < script` reach EOF. From a terminal, `-i` still reads it
- `voila run -h <name>` sets the hostname, as in Docker
- `ps`, `images` and `--version` print to stdout, so they can be piped
- `rm -f` is accepted, `--` ends flags for `rm`/`stop`, and unknown flags exit 2

### Install this build

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.5 --yes
```

## v0.1.0-alpha.4 — 2026-11-05

Fixes from the alpha.3 readiness pass (#163): containers get DNS and a hostname, `exec` joins the running container, `rmi` frees space, and cold lazy runs are 1.5–3.5× faster.

### Highlights

- Cold lazy runs: keep-alive chunk fetches, whole-file prefetch on 8 threads and a multi-threaded FUSE server (#147)
- `voila run`: DNS (`/etc/resolv.conf` via pasta), `/etc/hosts`, a per-container hostname, and the command waits until the network is up (#150, #151)
- Arguments after the image go to the `ENTRYPOINT`, as in Docker; new `--entrypoint`, `-u`, `--env-file`, `-h/--hostname`, `--network none`; `TERM` with `-t` (#152, #162)
- `voila exec` joins the running container (its files, processes, network and hostname) (#157)
- `voila tag`; push of an org-less ref goes to `$VOILA_ORG` (#159)
- `voila rmi` frees disk space and refuses images a running container uses (#155)
- `ADD` unpacks local tar, tar.gz and tar.zst archives (#160)
- Fixed: the `voila login` token was ignored when `VOILA_REGISTRY` was set (#149); `-p` without pasta hung (#153); a dead FUSE server left the container `running` (#154)
- Clearer errors for push (not authorized / needs an org), missing or private images, and `voila login` (#158, #161)
- Releases are published only after their binaries are attached; `install.sh` explains a missing asset (#156)
- `RUN` and `voila run` stay writable when the store is on overlayfs (#146)

### Install this build

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.4 --yes
```

## v0.1.0-alpha.2 — 2026-10-31

Second alpha: containers get their own network, the CLI reports real exit codes and readable errors, and push uploads chunks 16 at a time.

### Highlights

- Each `voila run` has its own network namespace. `-p` publishes ports onto the host; outbound traffic uses `pasta` when it is installed
- The process environment is the image `Env` plus `-e`. The command runs as the image `USER` when that id is mapped
- `voila --version` and command `--help`. Missing commands exit 127, sandbox failures exit 125, bad flags exit 2, and `ps` shows `exited (N)`
- `rm`, `stop`, `kill`, and `rmi` take more than one id. Errors print a short message instead of a Zig error name
- `voila push` uploads up to 16 chunks at once. `voila login` creates `~/.config/voila` when it is missing
- `voila build` warns when `uidmap` or a subuid range is missing, and keeps `RUN` scratch under `VOILA_ROOT` instead of `/tmp`
- Default registry is `https://registry.voila.build`

### Install this build

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.2 --yes
```

## v0.1.0-alpha.1 — 2026-10-26

First alpha candidate: lazy-mount runtime, rootless `voila build` / `voila run`, hosted registry push/pull, and CI-backed e2e coverage.

### Highlights

- Static musl CLI (`voila`) for linux amd64 and arm64
- Lazy chunk fetch on read; content-addressed store under `VOILA_ROOT`
- Dockerfile build with layer cache, rootless `RUN` (FUSE + user namespaces)
- Registry login, import, push, pull against the hosted drift registry
- Modular `cli/` layer (one file per subcommand)

### Verified (CI on `main`)

- `zig build test` (all layers)
- End-to-end pytest: hello run/build/push-pull, lifecycle (signals, cleanup, spaced roots), mock registry, Node `npm ci` build (peak RSS bound)

### Known limits

- Linux only; needs `/dev/fuse` and unprivileged user namespaces (AppArmor profile via `install.sh` on Ubuntu 24.04+)
- Dockerfile feature gaps — see issue #52
- Early software: expect API and behavior changes before beta

### Install this build

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.1 --yes
```
