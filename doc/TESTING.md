# Testing

## Tiers

| Tier | Where | Command | Needs |
|---|---|---|---|
| unit + integration | `test` blocks next to the code, wired in `src/all_tests.zig` | `zig build test` | nothing (temp dirs, fakes) |
| privileged | `src/privileged_tests.zig` | `zig build test -Dprivileged` | root or userns, `/dev/fuse`, nbd, erofs |
| build gate | `test/gates/build.sh [voila]` | see below | `/dev/fuse`, user namespaces, static busybox |
| legacy gates | `test/gates/gate*.sh`, `pg_coldstart.sh`, `e2e_auth.sh` | not maintained | Go release line |

- Tests use `std.testing.allocator`, so a leak fails the test.
- A bug fix comes with a test that fails without the fix.
- `zig fmt --check .` and `zig build test` run in CI (`.github/workflows/ci.yml`).

## The build gate

`test/gates/build.sh` exercises `voila build` end to end: `COPY`/`RUN`/`ENV`/
`WORKDIR`, whiteouts, opaque dirs, multi-stage, `.dockerignore`, the step
cache, invalidation and `RUN` failure reporting. It is fully local (`FROM
scratch` plus a static busybox, no registry or network).

```bash
test/gates/build.sh ~/.local/bin/voila
```

On Ubuntu 24.04+ the AppArmor profile from `install.sh` only allows user
namespaces for the installed binary's path, so pass that binary, not
`zig-out/bin/voila`.

## Legacy gates

`gate3.sh` … `gate9.sh`, `pg_coldstart.sh` and `e2e_auth.sh` were written for
the Go release line (`voilad`, runc, `go build`). Several still build Go code
and source `_build_standalone_registry.sh`. They are kept as references for
the scenarios and the benchmark numbers in [ARCHITECTURE.md](ARCHITECTURE.md)
until they are ported to the Zig CLI or removed.

## Fixtures

Real-image scenarios use `docker save` or `skopeo` tarballs, or import
directly from a registry:

```bash
voila import alpine:3.20
skopeo copy docker://alpine:3.20 oci-archive:/tmp/fixtures/alpine.tar
```
