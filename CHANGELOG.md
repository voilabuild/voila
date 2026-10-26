# Changelog

All notable changes to this project are documented here.

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
