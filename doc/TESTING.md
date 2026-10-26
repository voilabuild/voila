# Testing

| Tier | Where | Command | Needs |
|---|---|---|---|
| unit + integration | `test` blocks next to the code, listed in the layer's `src/<layer>/root.zig` | `zig build test` (one test binary per layer) | nothing (temp dirs, fakes) |
| privileged | `src/sys/privileged_test.zig` | `zig build test -Dprivileged` | user namespaces, `/dev/fuse` |
| end to end | `test/e2e/` | `cd test/e2e && uv run pytest` | `/dev/fuse`, user namespaces, network (Docker Hub) |

- Tests use `std.testing.allocator`, so a leak fails the test.
- A bug fix comes with a test that fails without the fix.
- CI (`.github/workflows/ci.yml`) runs `zig fmt --check .`, `zig build test`
  and the end-to-end tests on every pull request.

## End-to-end tests

`test/e2e/` drives the real `voila` binary the way a user does: it imports
images from Docker Hub, builds them with `voila build`, and pushes and pulls
through `registry.py`, a small in-memory registry (FastAPI) that follows
[`doc/registry/openapi.yaml`](registry/openapi.yaml) and counts the chunks it
serves, so tests can assert how much a run fetched. Each test machine is its
own `VOILA_ROOT` and `$HOME` under the test's temp dir.

```bash
zig build -Doptimize=ReleaseSafe
cd test/e2e
uv run pyright                 # strict type check
uv run pytest -v               # VOILA_BIN defaults to zig-out/bin/voila
uv run uvicorn registry:app --port 7423   # the registry on its own, for poking at by hand
```

On Ubuntu 24.04+ AppArmor allows user namespaces only for binaries named in an
`/etc/apparmor.d` profile (the one from `install.sh` names
`~/.local/bin/voila`). The suite stops with that message when `VOILA_BIN` is
not covered; install the build there and set `VOILA_BIN`, or run in the
devcontainer.

### Homelab smoke

After `install.sh` (or with `VOILA_BIN` pointing at your build):

```bash
bash test/homelab/acceptance.sh
```
