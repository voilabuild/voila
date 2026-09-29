# CLI reference

Three binaries (`make install` builds all of them):

- **`voila`**: the client CLI
- **`voilad`**: the worker daemon (root, Linux-only)
- **`voila-registry`**: the unprivileged chunk/manifest server

> ⚠️ Very early software, not even pre-alpha: flags and behavior may change
> at any time.

## Commands

| Command | What it does | Needs `voilad`? |
|---|---|---|
| `voila ingest <tarball> [-ref override] [-platform os/arch]` | Convert an OCI-layout or legacy `docker save` tarball into chunks + manifests | no |
| `voila import <ref> [-ref override] [-platform os/arch] [-user user] [-password pwd] [-plain-http] [-push target] [-registry URL]` | Pull an image straight from an OCI registry (Docker Hub / quay.io / ghcr.io / …) and ingest it, no Docker daemon needed. Credentials also via `$VOILA_REGISTRY_USER` / `$VOILA_REGISTRY_PASSWORD`. `-push myorg/img:tag` retags + publishes to a voila registry in the same command; in an interactive terminal with `$VOILA_REGISTRY` set, import offers this via a `[y/N]` prompt (`$VOILA_ORG` pre-fills the suggested org) | no |
| `voila images [info <ref> \| rm <ref> \| gc \| prune [-f]]` | List / inspect / remove ingested images; `gc` reclaims unreachable chunks; `prune` wipes ALL local images + chunks | no |
| `voila run <ref> [--] <cmd...> [-memory bytes] [-cpus pct]` | Run an ingested image via the worker daemon | yes |
| `voila exec <ctx-id> [--] <cmd...>` | Run an extra process in a running context | yes |
| `voila logs [-follow] <ctx-id>` | Replay (and optionally follow) a context's ring-buffered output | yes |
| `voila ps` | List contexts known to the daemon | yes |
| `voila kill [-signal N] <ctx-id>` | Signal a running context (default SIGTERM, escalating to SIGKILL after a 3s grace if the container is still running; other signals are delivered as-is) | yes |
| `voila push <ref> [-registry URL]` | Upload an image's chunk closure + ImageManifest to a registry | no |
| `voila pull <ref> [-registry URL]` | Fetch an image's manifest from a registry (chunks stream on demand) | no |
| `voila login [registry-url] [-root dir]` | Save registry URL + API key to `~/.config/voila/credentials` (0600); probes auth via `POST /v1/chunks/missing` | no |
| `voila logout` | Remove saved registry credentials | no |
| `voilad [-root dir] [-socket path] [-registry URL] [-trace]` | The worker daemon (root, Linux); serves gRPC on `/var/run/voila.sock`. `-trace` records a per-run chunk-access trace (JSONL: every chunk Get with hit/miss, wait time, demand/prefetch source, plus exec/exit phase markers) under `<root>/traces/` — explore with `jq`/`duckdb` | **is** the daemon |
| `voilad mount <ref> <mountpoint> [-allow-other]` | Debug: mount a read-only FUSE view of an ingested image | no |
| `voila-registry [-root dir] [-listen :7423]` | The HTTP chunk + ImageManifest registry server (unprivileged) | no |

## Environment variables

- `VOILA_ROOT`: voila data root directory (default `/var/lib/voila`);
  every subcommand also accepts `-root`. Set to `~/.voila` for an
  unprivileged, per-user setup.
- `VOILA_SOCKET`: worker daemon's unix socket path (default
  `/var/run/voila.sock`); daemon-talking subcommands also accept `-socket`.
  When `-root` is set explicitly, the socket defaults to `<root>/worker.sock`.
- `VOILA_REGISTRY`: URL of a `voila-registry`, used by push/pull/import
  (also `-registry`). For a registry serving under a path prefix, set the
  full base, e.g. `http://localhost:7423/registry`; the client appends
  `/v1/...`. `voilad` also reads this (or `-registry`) for the registry
  base URL; the bearer token is handed off separately (below). Precedence:
  `-registry` flag, then `$VOILA_REGISTRY`, then `~/.config/voila/credentials`
  from `voila login`.
- `VOILA_REGISTRY_TOKEN`: bearer API key for the **CLI** (`push`/`pull`/
  `import`). Configure it in your shell or via `voila login` — not in the
  daemon's environment. Precedence: `$VOILA_REGISTRY_TOKEN`, then the login
  file. Before `run`/`push`/`pull`, the CLI writes URL + token to
  `<root>/registry.creds` (0600) and pushes them to a running `voilad` via
  the `SetRegistry` RPC on the worker socket. Chunk GETs stay unauthenticated
  on the wire; the token is used for manifest auto-pull and authenticated
  registry endpoints only. When neither env vars nor a login file provide
  credentials, push/pull/import error with "run `voila login`".
- Registry manifest errors are reported per HTTP status: a `404` on pull
  prints `image "<ref>" not found on <registry> (ref may be wrong, or the
  image is private)` — private images intentionally return 404 to non-owners,
  so 404 cannot distinguish "missing" from "no access". An explicit `401/403`
  prints `not authorized ... (check VOILA_REGISTRY_TOKEN or run voila login)`.
- `VOILA_RUNTIME_BIN`: override the runc binary (`crun`/`youki` work via the
  `Runner` interface; defaults to `runc` on `$PATH`).
- `VOILA_REGISTRY_USER` / `VOILA_REGISTRY_PASSWORD`: credentials for
  `voila import` against a private OCI registry (also `-user` / `-password`).
- `VOILA_ORG`: your registry org namespace; used only by the
  `voila import` publish prompt to pre-fill the suggested target ref
  (e.g. `$VOILA_ORG=acme` suggests `acme/python:3.13`).
- `VOILA_E2E_TARBALL`: point `test/e2e.TestRealImage` at a real
  `docker save` tarball (otherwise the test skips).
- `VOILA_MOUNT_BACKEND`: `auto` (default), `fuse`, or `erofs`. Auto uses
  EROFS+NBD when Linux is 5.15+, `erofs` is available, and a `/dev/nbd*`
  node opens; otherwise FUSE. Only `voilad` reads this.
