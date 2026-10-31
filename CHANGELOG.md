# Changelog

All notable changes to this project are documented here.

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
