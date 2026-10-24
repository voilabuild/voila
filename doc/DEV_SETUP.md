# Dev environment setup

voila is Linux only. Building and the unit tests work anywhere Zig runs;
`voila run`, `voila build` with `RUN`, and the privileged tests need Linux with
`/dev/fuse` and unprivileged user namespaces.

## Toolchain

[mise](https://mise.jdx.dev) pins Zig in `.mise.toml` (versions and checksums
locked in `mise.lock`):

```bash
mise install          # zig 0.17.0
zig build             # zig-out/bin/voila (Debug)
zig build -Doptimize=ReleaseFast
zig build test        # unit + integration tests, no root
zig build test -Dprivileged   # needs root, /dev/fuse, nbd, erofs
zig fmt --check .
```

C dependencies (BLAKE3, zstd, SQLite, libfuse3) are fetched by
`build.zig.zon` and built from source, so no system `-dev` packages are needed.

## Linux host

- `fuse3` for `fusermount3`.
- Optional: `uidmap` plus an `/etc/subuid` / `/etc/subgid` range for your
  user, so `RUN` steps can switch users and `chown`.
- Ubuntu 24.04+ restricts unprivileged user namespaces with AppArmor. The
  profile from `install.sh` allows them only for the installed binary path
  (`/usr/local/bin/voila` or `~/.local/bin/voila`), so a dev build in
  `zig-out/` cannot run containers unless you add its path to the profile or
  test from the installed location.

## macOS

Use the devcontainer (`.devcontainer/`): a privileged Debian container with
`fuse3`, `uidmap`, `skopeo` and the pinned Zig. Open the repo in VS Code and
choose "Reopen in Container", or run `devcontainer up`.

## Tests

See [TESTING.md](TESTING.md).
