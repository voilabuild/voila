# CLI reference

One static binary, `voila` (Linux only). There is no daemon: each command
works directly on the local store, and `voila run` starts a rootless FUSE
server per container. The hosted registry service lives in
[`voilabuild/cloud-registry`](https://github.com/voilabuild/cloud-registry);
this repo ships the registry client (`login`, `import`, `pull`, `push`).

> ⚠️ Very early software: flags and behavior may change at any time.

## Commands

Every command accepts `--root <dir>` (also `-root`; default: `$VOILA_ROOT`).
`voila <command> --help` prints that command's usage.

| Command | What it does |
|---|---|
| `voila login [registry-url]` | Save the registry URL and API key to `~/.config/voila/credentials` (0600) |
| `voila logout` | Remove saved registry credentials |
| `voila import <ref>` | Pull an image from an OCI registry (Docker Hub, ghcr.io, …) and store it as chunks. No Docker daemon needed |
| `voila pull <ref>` | Fetch an image's manifest from the voila registry; chunks stream on first read |
| `voila push <ref>` | Upload an image's missing chunks (up to 16 at a time) and its manifest to the voila registry |
| `voila build -t <ref> [-f Dockerfile] [--build-arg K=V]... [--target stage] [--no-cache] [--push] <context>` | Build an image from a Dockerfile (see [Building images](#building-images)) |
| `voila run [-d] [-it] [--name N] [--rm] [-e K=V] [-v host:ctr] [-p host:ctr] [-w dir] <ref> [--] [cmd...]` | Run a container (see [Running containers](#running-containers)) |
| `voila exec <id> [--] <cmd...>` | Run an extra process in a running container |
| `voila ps` | List containers (`exited (N)` includes the command's exit code) |
| `voila logs [-f/--follow] <id>` | Print (and optionally follow) a container's output |
| `voila stop <id> [id…]` / `voila kill [-s N] <id> [id…]` / `voila rm <id> [id…]` | Stop, signal or remove one or more containers |
| `voila images` / `voila rmi <ref> [ref…]` | List or remove local images. `rmi` of a missing ref prints `voila rmi: no such image …` and exits 1 |
| `voila --version` | Print `voila <version> (<commit>)` |

## Building images

`voila build` runs a Dockerfile against the chunk store and tags the result
like any imported image, so `voila run` and `voila push` work on it unchanged.

- Supported: `FROM` (any local or registry image, or `scratch`), `RUN` (shell
  and exec form), `COPY`/`ADD` from the build context (`--chown=user[:group]`
  by number or name in the image's `/etc/passwd` and `/etc/group`;
  `--chmod=<octal>`; `*`/`?` wildcards in the last path segment), `ENV`, `ARG`
  (with `--build-arg`), `WORKDIR`, `USER`, `CMD`, `ENTRYPOINT`, `EXPOSE`,
  `LABEL`, `SHELL`, `HEALTHCHECK`, `STOPSIGNAL`, `VOLUME`, `MAINTAINER`, line
  continuations, comments and `.dockerignore`.
- Multi-stage: `FROM <image|earlier stage> [AS name]`, global `ARG`s before the
  first `FROM`, `COPY --from=<stage name|index|image>` (with `--chown` /
  `--chmod`). Only stages the target depends on are built; `--target <stage>`
  tags that stage. Progress lines show the stage: `[builder 2/4] RUN ...`.
- Not supported yet: `RUN --mount`, `ADD --from`, `ADD` of URLs or tar
  auto-extraction, heredocs, `ONBUILD`, symbolic `--chmod` modes.
- Every `RUN`, `COPY` and `ADD` step is cached under `<root>/build-cache/`,
  keyed by the parent image, the instruction, its environment and (for
  `COPY`) the content of its sources, or for `COPY --from` the source
  stage's root chunk and paths. A rebuild with no changes does no work;
  `--no-cache` ignores the cache.
- `RUN` is rootless: it needs `/dev/fuse` and unprivileged user namespaces
  (on Ubuntu 24.04+, the AppArmor profile installed by `install.sh`). Like
  rootless Podman, the user namespace maps 0 to you and 1..N to your
  `/etc/subuid` / `/etc/subgid` range, written with `newuidmap` /
  `newgidmap` from `/usr/bin` (package `uidmap`). Then `su`, `apt-get`'s
  `_apt` sandbox and `chown` to other ids work, and layers keep those owners.
  Without the helpers or a subid entry, `RUN` falls back to a single-uid
  namespace: namespace root still cannot open files owned by unmapped uids
  (`_apt`, `shadow`), so `apt-get` and `useradd` fail. `voila build` prints
  a warning before the first `RUN` telling you to install `uidmap`.
- `USER` applies to later `RUN` steps: `user[:group]` names are looked up in
  the image's `/etc/passwd` and `/etc/group`, numeric ids always work (gid
  defaults to the user's group, or 0), and `HOME` is set from `/etc/passwd`
  when unset. Without the subid range, a non-root `USER` is not applied to
  `RUN` (it runs as root, as before) and `voila build` prints one warning.
- Each `RUN` command is pid 1 of its own PID namespace; background processes
  it leaves behind are killed when it exits.

## Running containers

`voila run` always runs the command inside the image root, so absolute
paths resolve inside the image, with or without `-w`, `-v`, `-it` or `-p`. The
command runs as PID 2 under a small init in its own user, mount, PID and
network namespaces, with a fresh `/proc`, a minimal `/dev` (`null`, `zero`, `full`,
`random`, `urandom`, `tty`, `pts`, `shm`) and a fresh `sysfs` (or a read-only
bind of the host's `/sys` if that mount is refused); the host filesystem is not
reachable. Listening sockets stay in the container: they are not on `0.0.0.0`
on the host, and two containers can bind the same port. The process environment is the
image `Env` plus `-e` (a default `PATH` and `HOME` from the image `USER`'s
`/etc/passwd` entry, or `HOME=/root` if the image sets neither); the host
environment is not inherited. The command runs as the image `USER` when that
id is mapped in the user namespace; without a subuid range it stays root and
`voila` prints a warning. The image root is writable: writes
go to `<root>/containers/<id>/rw` on disk and are deleted with the container
(`--rm` or `voila rm`). A `-v` target missing from the image is created. With
`-it` the terminal comes from the container's own `/dev/pts`, so `tty` works.
Without `-it`, output goes to the container log (`voila logs`) and a foreground
run prints it when the command exits. `voila run -d` prints the container id
only after the sandbox is up, including `-p` forwards; a failure to start
(or to publish ports) exits non-zero without an id. `-p host:ctr` publishes a TCP port onto
the host (`-p 8080:8080` is allowed). Outbound traffic uses `pasta` from the
`passt` package when it is installed; without `pasta` the container has
loopback only and `voila` prints a warning, but `-p` still works. Signals
such as the `SIGTERM` from `voila stop` are forwarded to the command. Exit
codes: the command's own, 128 + signal when it is killed, 125 when the sandbox
cannot be set up, 126 when the command cannot be executed and 127 when it is
not found. An unknown flag before the image exits 2 without creating a
container. It needs `/dev/fuse` and unprivileged user namespaces (on Ubuntu
24.04+, the AppArmor profile installed by `install.sh`). When they are
unavailable, `run` exits with an error. It does not fall back to running on the
host. With `uidmap` and a subuid range, the run sandbox maps the same range
`build` uses; without them it falls back to a single-uid namespace and prints
a warning.

## Environment variables

- `VOILA_ROOT`: data root. Default: `/var/lib/voila` when it exists,
  otherwise `~/.local/share/voila`. `--root` / `-root` overrides it.
- `VOILA_REGISTRY`: voila registry base URL used by `pull`, `push`, `import`
  and lazy chunk fetches. For a registry served under a path prefix, give the
  full base (e.g. `https://host/registry`); the client appends `/v1/...`.
  Precedence: `$VOILA_REGISTRY`, then `~/.config/voila/credentials`.
- `VOILA_REGISTRY_TOKEN`: registry API key. Precedence:
  `$VOILA_REGISTRY_TOKEN`, then the login file. Chunk GETs are
  unauthenticated; the token is used for manifests and uploads.
- `VOILA_ORG`: your registry org. Default namespace for an explicit
  `voila push` or `voila build --push`. `import` and `FROM` resolution
  keep the Hub ref and do not upload anything.
- `VOILA_RUNTIME`: `local` (default) or `remote`. `remote` is not
  implemented yet.

Registry errors are reported per HTTP status. A `404` on pull prints `image
"<ref>" not found on <registry>`: private images return 404 to non-owners, so
404 cannot tell "missing" from "no access". A `401`/`403` prints `not
authorized ... (check VOILA_REGISTRY_TOKEN or run voila login)`. Other CLI
errors print a short message instead of a Zig error name; unknown errors ask
you to report them with `voila --version`.
