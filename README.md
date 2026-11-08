# voila

Run a container without downloading the whole image first.

To run `python -c 'print(1)'`, Docker pulls the entire image (hundreds of
megabytes) even though the command touches only a small part of it. voila
stores images as 1 MiB content-addressed chunks and mounts the filesystem
lazily: a chunk is downloaded only when a process reads a file that needs it.

## Be warned: this is a toy project

voila is an experiment, not a Docker replacement. It's alpha software
(`v0.1.0-alpha.6-rc.3`, [changelog](CHANGELOG.md)) and you should expect it to
break. Don't run anything you care about on it.

- Linux only. One static binary, no daemon, runs rootless (user namespaces
  and FUSE).
- It covers the common Docker commands (`run`, `build`, `push`, `ps`,
  `exec`, `logs`, `-p`, `-v`, `-e`), but not everything. For example,
  `--network host`, compose and Windows/macOS aren't supported.
- The hosted registry (registry.voila.build) is a single small deployment;
  chunks are served through Cloudflare's CDN.

## Numbers

Measured on a stock GitHub `ubuntu-24.04` runner (4 CPUs) by
[voila-bench](https://github.com/voilabuild/voila-bench). Every run starts
from an empty machine: Docker pulls the official image from Docker Hub,
voila runs the same image straight from registry.voila.build. Times include
getting the image.

**A CI job: build and test a small project**

| Job | Docker | voila | Downloaded: Docker / voila |
|---|---|---|---|
| Go: `go vet`, `go build`, `go test` (`golang:1.23`) | 28.5 s | 22.1 s | 623 / 310 MB |
| Python: `pip install pytest`, `pytest` (`python:3.12`) | 18.2 s | 6.9 s | 849 / 161 MB |
| Node: `npm test` (`node:22`) | 15.4 s | 5.7 s | 839 / 182 MB |

**Starting a service, until it answers a request**

| Service | Docker | voila | Downloaded: Docker / voila |
|---|---|---|---|
| postgres 16 (`postgres:16`) | 6.5 s | 4.1 s | 329 / 204 MB |
| redis 7 (`redis:7`) | 2.1 s | 1.0 s | 90 / 55 MB |
| Next.js 15 app (`node:22`) | 15.8 s | 3.1 s | 838 / 173 MB |

Medians of 3 runs each, voila built from
[`perf/prefetch-dirs`](https://github.com/voilabuild/voila/tree/perf/prefetch-dirs)
(not released yet) and Docker 28.0.4, on 2026-11-08
([CI jobs](https://github.com/voilabuild/voila-bench/actions/runs/42446426119),
[services](https://github.com/voilabuild/voila-bench/actions/runs/42450191191)).
"Downloaded" is what the runner's network interface received.

What this shows:

- **voila wins by skipping the pull.** Docker spends most of these runs
  downloading the image (13-15 s for the big ones), and a short job like
  `npm test` then takes under a second. voila starts right away and fetches
  only the files the job reads, so the bigger the image and the shorter the
  job, the bigger the win.
- **A job that reads many files is closer.** `go build` reads thousands of
  small standard-library files, and each one not yet fetched costs a round
  trip. voila fetches the other files of a directory as soon as one is
  read, which brought Go from 29.7 s to 22.1 s, but that's still the job
  where Docker comes closest.
- **The first run can be much slower.** In an earlier run the very first
  voila Go job took 189 s and Node 115 s, probably because the CDN edge had
  never seen those chunks. Later runs were normal. A popular image would
  rarely hit this; one nobody has pulled lately might.

These numbers come from one shared VM and move between runs (the same build
measured 30-40% apart on different days). Treat them as a rough picture,
not a promise.

## Try it

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.6-rc.3 --yes

voila import alpine:3.20                    # copy an image from Docker Hub
voila run --rm alpine:3.20 -- echo hi
voila run --rm -it alpine:3.20 sh
voila build -t myapp:1 . && voila run --rm myapp:1
```

The script checks the download's checksum and sets up the AppArmor profile
that Ubuntu 24.04+ needs. Other options are in [doc/INSTALL.md](doc/INSTALL.md).

To share images, sign up at https://registry.voila.build, run `voila login`,
then `voila push <org>/myapp:1`. On another machine, `voila login` and then
`voila run <org>/myapp:1` starts without pulling the image first. Images are
private to your org by default, which is why the second machine logs in too.

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
