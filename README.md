# voila

Run a container without downloading the whole image first.

To run `python -c 'print(1)'`, Docker pulls the entire image (hundreds of
megabytes) even though the command touches only a small part of it. voila
stores images as 1 MiB content-addressed chunks and mounts the filesystem
lazily: a chunk is downloaded only when a process reads a file that needs it.

## Be warned: this is a toy project

voila is an experiment, not a Docker replacement. It's alpha software
(`v0.1.0-alpha.7`, [changelog](CHANGELOG.md)) and you should expect it to
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

| Job | Docker | voila | voila, first run | Downloaded: Docker / voila |
|---|---|---|---|---|
| Go: `go vet`, `go build`, `go test` (`golang:1.23`) | 29.3 s | 25.1 s | 34.6 s | 623 / 311 MB |
| Python: `pip install pytest`, `pytest` (`python:3.12`) | 18.7 s | 15.5 s | 15.5 s | 850 / 161 MB |
| Node: `npm test` (`node:22`) | 16.0 s | 15.3 s | 23.9 s | 838 / 182 MB |

**Starting a service, until it answers a request**

| Service | Docker | voila | voila, first run | Downloaded: Docker / voila |
|---|---|---|---|---|
| postgres 16 (`postgres:16`) | 5.9 s | 3.8 s | 4.3 s | 329 / 205 MB |
| redis 7 (`redis:7`) | 2.0 s | 0.8 s | 0.8 s | 90 / 56 MB |
| Next.js 15 app (`node:22`) | 13.9 s | 3.0 s | 2.7 s | 838 / 173 MB |

Medians of 3 runs each (the first run is one of the 3), for voila
`v0.1.0-alpha.7` and Docker 28.0.4 on 2026-11-10
([CI jobs](https://github.com/voilabuild/voila-bench/actions/runs/42740505462),
[services](https://github.com/voilabuild/voila-bench/actions/runs/42739192483)).
"Downloaded" is what the runner's network interface received. Docker's
first run is within about a second of its median.

What this shows:

- **voila wins by skipping the pull.** Docker spends most of these runs
  downloading the image (14-15 s for the big ones), and a short job like
  `npm test` then takes under a second. voila starts right away and fetches
  only the files the job reads, so the bigger the image and the shorter the
  job, the bigger the win. Services, which read little before they answer,
  show it best.
- **CI jobs depend on the distance to the CDN.** A job reads thousands of
  chunks, and voila waits on many of them in turn. Every chunk here was a
  CDN cache hit, answered in 32-58 ms (median) by the edge the runner
  landed on. On a runner whose edge answered in 22 ms (2026-11-08, an
  earlier build of this release), the same jobs took 20.9 s (Go), 8.3 s
  (Python) and 11.5 s (Node)
  ([run](https://github.com/voilabuild/voila-bench/actions/runs/42537225931)).
- **The first run is slower, and can lose.** On the first run the edge
  often fetches each chunk from an upper cache tier before keeping it
  (Node: 57 ms per chunk instead of 32 ms), so the first `npm test` took
  23.9 s, longer than Docker's 16.0 s. A CI fleet that keeps running the
  same images warms its edge; a one-off run doesn't.
- **A job that reads many files is closest.** `go build` reads thousands of
  small standard-library files, and each one not yet fetched costs a round
  trip. voila fetches the other files of a directory as soon as one is
  read, and up to 64 chunks at once, but this is still where Docker comes
  closest.

These numbers come from one shared VM and move between runs: another run
the same day, on a runner with a slower disk and a 449 ms p90 chunk
latency, measured Python at 24.5 s and Node at 32.8 s
([run](https://github.com/voilabuild/voila-bench/actions/runs/42739185269)).
Treat them as a rough picture, not a promise.

## Try it

```bash
curl -fsSL https://github.com/voilabuild/voila/raw/main/install.sh | sh -s -- --version v0.1.0-alpha.7 --yes

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
