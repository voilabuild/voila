# Testing

voila's verification strategy has three layers: **darwin-runnable unit tests**
for the OS-independent core, **build-tagged Linux edge tests** for the FUSE /
runc paths, and **verification gates** run inside the privileged devcontainer
(one gate per milestone).

## Philosophy

- **Unit tests everywhere they can run.** The pure-Go core — `internal/chunkstore`
  (BLAKE3, zstd, sqlite index), `internal/proto`, `internal/ingest` (OCI/docker-save
  parsing, whiteouts, hardlinks, the lower→upper merge), `internal/worker` (context
  FSM, ring buffer, event hub) — is OS-independent and runs on macOS. The
  Linux-only edges (FUSE ops in `internal/mount`, runc invocation in
  `internal/runtime`, the gRPC server plumbing) are build-tagged so `go test ./...`
  on macOS skips them harmlessly.
- **Verification gates in the privileged devcontainer.** Mount + runc need
  Linux with `CAP_SYS_ADMIN` (EROFS+NBD and/or FUSE); nested runc needs
  namespace + cgroup access. macOS has neither, so gates 3+ run inside the
  devcontainer (`mcr.microsoft.com/devcontainers/go:1-bookworm` with
  `--privileged`; see `.devcontainer/devcontainer.json`). Gates 1–2 are pure
  Go and also run directly on macOS.
- **One gate per milestone.** Each gate is a small `test/gates/gateN.sh` bash script
  that proves a slice of the milestone checklist end to end (ingest → mount → run →
  assert → tear down), with assertions, not just "it ran".

## Gates

| Gate | What it proves | Script | Fixture needed |
|---|---|---|---|
| 1 | chunkstore `Put`/`Get` roundtrip incl. transparent zstd decode; `GC` removes exactly the unreachable chunks and nothing referenced by an `ImageManifest` | (covered by `internal/chunkstore` unit tests; darwin-runnable) | none |
| 2 | ingest: OCI-layout **and** legacy `docker save`; hardlinks resolve to one inode; whiteouts + opaque whiteouts absent from merged root; uid/gid/mode/xattrs preserved; roundtrip hash test | (covered by `test/e2e` roundtrip tests; darwin-runnable) | none (synthetic) |
| 3 | Read-only mount (FUSE path): `ls -R` walks the tree, `cat /etc/os-release` works, writes refused, hardlink inode shared, sequential read latency measured | `test/gates/gate3.sh` | `alpine.tar` |
| 4 | runc runtime: `voila run` produces stdout, exit code propagates, `/tmp` non-persistence, RO rootfs, env + private netns, clean teardown | `test/gates/gate4.sh` | `alpine.tar` |
| 5 | worker daemon: run-via-daemon, `exec` into running ctx, `logs` replay (exec output excluded), detach (client kill → ctx keeps running), `kill`, `images info/rm/gc` | `test/gates/gate5.sh` | `alpine.tar` |
| 6 | **v0.1 acceptance** (plan §11.6): `python:3.13` `print("hi")` < 1 s wall; stdlib import check; `postgres:16` initdb + server + real SQL round trip on RO rootfs with PGDATA on tmpfs | `test/gates/gate6.sh` | `python313.tar`, `postgres16.tar` |
| 7 | **Phase 1 acceptance**: two-machine flow (two voila roots). A ingests + pushes to a registry; B (empty) pulls manifest only (0 chunks); cold-start `voila run` streams chunks lazily over HTTP; warm rerun downloads nothing; re-push idempotent | `test/gates/gate7.sh` | `alpine.tar` |
| 8 | **Phase 1.1 acceptance**: layer cache + delta push. Image B sharing A's base layer ingests in ms reusing the cached layer (`layers reused: 1/2`); a one-file change pushes only its chunks + manifests; optional python re-ingest shows 7/7 layers cached | `test/gates/gate8.sh` | none (self-generating; `python313.tar` optional) |

## How to run

### Unit tests

```bash
make check     # build + vet + CGO_ENABLED=0 go test ./...
make test      # CGO_ENABLED=0 go test ./...
go test -race ./internal/...   # race detector on the daemon/goroutine-heavy core
```

These run on macOS and Linux alike (Linux-only edge tests opt in via build tags).

### A single gate (devcontainer)

Grab a fixture (synthetic gates 3/4/5/7 only need `alpine.tar`; gate 6 needs
`python313.tar` and `postgres16.tar`):

```bash
# on the host (no docker-in-docker needed for fetching; skopeo also works)
docker pull alpine:3.20 && docker save alpine:3.20 -o /tmp/fixtures/alpine.tar
```

Then run the gate inside the privileged devcontainer, mounting the fixture
directory and the Go module cache so the container doesn't re-download the
world:

```bash
docker run --rm --privileged \
  -v "$PWD:/workspace" -v /tmp/fixtures:/fixtures \
  -v "$(go env GOMODCACHE):/gocache" -e GOMODCACHE=/gocache \
  -w /workspace \
  mcr.microsoft.com/devcontainers/go:1-bookworm \
  bash test/gates/gate5.sh /fixtures/alpine.tar
```

Replace `gate5.sh` with the gate you want (gates 3, 4, 5, 7 all take the
tarball as `$1`; gate 6 reads `/fixtures/python313.tar` and
`/fixtures/postgres16.tar` and runs both).

### All gates

There is no `run-all-gates` target by design: gate 6 needs
`python:3.13` + `postgres:16` (multi-minute ingests) and is skipped in CI for
time. Run gates 3, 4, 5, 7 for the alpine loop and gate 6 manually when you
want the v0.1 acceptance bar. `make gates` prints the canonical `docker run`
line for each gate so you don't have to remember the volume-mount incantation.

## Fixtures: synthetic vs real-image

- **Synthetic** — `test/e2e/fixtures_test.go` builds deterministic 2-layer OCI
  and legacy docker-save tarballs in memory, exercising hardlinks, xattrs,
  type changes, explicit + opaque whiteouts, and the gzip/zstd/raw compression
  matrix. They are the source of truth for `TestRoundtrip`, `TestDedup`,
  `TestDeterminism`. No `docker` needed.
- **Real-image** — gates 3–7 each take a `docker save` (or `skopeo copy …
  oci-archive:`) tarball as `$1`. Make them with:

  ```bash
  docker pull alpine:3.20         && docker save alpine:3.20         -o /tmp/fixtures/alpine.tar
  docker pull python:3.13         && docker save python:3.13         -o /tmp/fixtures/python313.tar
  docker pull postgres:16         && docker save postgres:16         -o /tmp/fixtures/postgres16.tar
  # or, daemonlessly:
  skopeo copy docker://alpine:3.20 oci-archive:/tmp/fixtures/alpine.tar
  ```

There is no `mkfixture` script — `docker save` / `skopeo` *are* the fixture
makers; the gates stream directly off the resulting tarball.

## The e2e roundtrip test + `VOILA_E2E_TARBALL`

`test/e2e/roundtrip_test.go` is the gate-2 workhorse:

- `TestRoundtrip` — table-driven across `OCI_gzip` / `OCI_zstd` / `OCI_raw` /
  `Legacy`: builds a synthetic image, ingests it, and re-reads every regular
  file's blocks back from the store and asserts SHA-256 equality with the
  source content; hardlinked names share an inode; whiteout'd paths are
  absent; uid/gid/mode/xattrs survive.
- `TestDedup` — ingesting the same fixture twice reports every chunk as
  deduped and the on-disk chunk count is unchanged.
- `TestDeterminism` — the merged root manifest chunk id is identical across
  two fresh stores for the same fixture.
- `TestRealImage` — **skipped by default**. Set `VOILA_E2E_TARBALL` to a real
  `docker save`/OCI tarball path to run the roundtrip-hash assertion on a
  sample of 20 files plus `/etc/os-release`. Use it to spot-check ingest
  against real images on macOS without standing up the full devcontainer:

  ```bash
  VOILA_E2E_TARBALL=/tmp/python313.tar go test ./test/e2e/ -run TestRealImage -v
  ```
