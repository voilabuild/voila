# Changelog

All notable changes to this project are documented here.

## v0.1.0-alpha.6-rc.2 — 2026-11-08

Release candidate. Faster cold runs from the registry, three data-safety fixes, and a timing trace.

### Highlights

- Cold runs fetch the other files of a directory as soon as one is read (no subdirectories; directories over 8 MiB of files are skipped). On a fresh GitHub runner: Go `vet`/`build`/`test` 29.7 → 22.1 s, `pytest` 11.3 → 6.9 s, `npm test` 9.2 → 5.7 s, postgres ready 4.6 → 4.1 s, for 4–30 MB more download. `--no-prefetch-dirs` turns it off
- Fewer round trips before the first read: the chunk endpoint is looked up once per run and passed to the FUSE server, manifests come over pooled keep-alive connections, and connections are warmed during mount
- `VOILA_TRACE=<file>` writes a Chrome/Perfetto trace from every voila process (CLI, worker, FUSE server, container setup): phases, HTTP requests with CDN cache status, chunk fetches, FUSE operations. `tools/trace_summary.py` summarizes one
- README: what voila is, an honest "toy project" section, and numbers from real CI jobs and service starts against Docker ([voila-bench](https://github.com/voilabuild/voila-bench))

### Fixed

- A file whose first bytes are the zstd magic (any `.zst` file in an image) read back empty, with exit 0, after a lazy pull from a registry that stores chunks decoded. The fetch now verifies the chunk as-is before decoding it
- Pushing such a file sent its chunk unwrapped, and the hub rejected it (`golang:1.23` could not be pushed)
- A chunk slower than the request timeout crashed the FUSE server mid-read; it now fails the read with "timed out"
- A short run against a slow registry could crash at exit (connection warm-up used memory already freed)
- (rc.2) A warm run no longer waits at exit for prefetches of files it never read (rc.1: warm `run --rm` 0.5-0.9 s instead of 0.09 s), and dropped prefetches are not printed as errors

### Install this build

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.6-rc.2 --yes
```

## v0.1.0-alpha.5 — 2026-11-05

Fixes from validating alpha.4 against a Docker-user scenario (#166).

### Highlights

- `voila run` without `-p` no longer waits ~1 s at exit: Ubuntu's pasta AppArmor profile refuses voila's signal, and the run now returns without waiting for pasta (warm `run --rm alpine true`: 1.06 s → 0.05 s). With `-p` it still waits for pasta (at most 1.5 s), so the host port is free when the run returns
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
