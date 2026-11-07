# voila

Run a container without downloading the whole image first.

To run `python -c 'print(1)'`, Docker pulls the entire image (hundreds of
megabytes) even though the command touches only a small part of it. voila
stores images as 1 MiB content-addressed chunks and mounts the filesystem
lazily: a chunk is downloaded only when a process reads a file that needs it.

## Be warned: this is a toy project

voila is an experiment, not a Docker replacement. It's alpha software
(`v0.1.0-alpha.5`, [changelog](CHANGELOG.md)) and you should expect it to
break. Don't run anything you care about on it.

- Linux only. One static binary, no daemon, runs rootless (user namespaces
  and FUSE).
- It covers the common Docker commands (`run`, `build`, `push`, `ps`,
  `exec`, `logs`, `-p`, `-v`, `-e`), but not everything. For example,
  `--network host`, compose and Windows/macOS aren't supported.
- The hosted registry (registry.voila.build) is a single small deployment,
  not a CDN.

## Numbers

Measured on a stock GitHub `ubuntu-24.04` runner (4 CPUs) by
[voila-bench](https://github.com/voilabuild/voila-bench), which re-runs every
week. Docker pulls from Docker Hub; voila runs the same image straight from
registry.voila.build.

| `python -c 'print(1)'` on an empty machine | Docker | voila |
|---|---|---|
| `python:3.12-slim` (119 MB unpacked) | 3.2 s, 89 MB downloaded | 2.3 s, 22 MB downloaded |
| `python:3.12` (1.1 GB unpacked) | 16.6 s, 846 MB downloaded | 2.4 s, 68 MB downloaded |

| Image already local | Docker | voila |
|---|---|---|
| alpine `true` | 175 ms | 67 ms |
| python `print(1)` | 191 ms | 118 ms |

Medians of 3 cold runs and 10 warm runs on voila 0.1.0-alpha.5 and Docker
28.0.4 ([run](https://github.com/voilabuild/voila-bench/actions/runs/42324931048)).

What this shows:

- **voila downloads a fraction of the image.** It fetches only the file data
  the command reads, so the bigger the image, the bigger the win: 68 MB
  instead of 846 MB for the full Python image.
- **The first run on a runner is slower.** For both tools, the first cold
  start was the slowest of the three: voila took 4.5 s (slim) and 5.0 s
  (full), Docker 4.6 s and 17.6 s. The medians above are the later runs. A
  separate quick run once took voila 7.1 s and Docker 4.7 s, so on a bad
  day Docker can win a small image.
- **Warm runs are quicker** because there's no daemon in the way.

These numbers come from one shared VM and move between runs. Treat them as
a rough picture, not a promise.

## Try it

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.5 --yes

voila import alpine:3.20                    # copy an image from Docker Hub
voila run --rm alpine:3.20 -- echo hi
voila run --rm -it alpine:3.20 sh
voila build -t myapp:1 . && voila run --rm myapp:1
```

The script checks the download's checksum and sets up the AppArmor profile
that Ubuntu 24.04+ needs. Other options are in [doc/INSTALL.md](doc/INSTALL.md).

To share images, sign up at https://registry.voila.build, run `voila login`,
then `voila push <org>/myapp:1`. On another machine, `voila run
<org>/myapp:1` starts without pulling the image first. Images are private to
your org by default.

## How it works

1. **Store.** `voila import` and `voila build` cut every file into 1 MiB
   chunks named by their BLAKE3 hash, plus a small manifest tree. Identical
   data is stored once.
2. **Mount.** `voila run` starts a FUSE server for the image. Reading a file
   fetches its chunks from the local store, or from the registry if they're
   missing.
3. **Run.** The command runs in its own user, mount, PID and network
   namespaces. Its writes go to a per-container directory.

More detail: [architecture](doc/ARCHITECTURE.md), [CLI reference](doc/CLI.md),
[testing](doc/TESTING.md). To build from source: `mise install && zig build
-Doptimize=ReleaseFast` (see [doc/DEV_SETUP.md](doc/DEV_SETUP.md)).
