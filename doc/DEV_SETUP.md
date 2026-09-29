# Dev environment setup

There are two supported local setups. Both use **[mise](https://mise.jdx.dev)**
to provision the Go toolchain and codegen tools from a single pinned, locked
config (`.mise.toml` + `mise.lock`), so `mise install` reproduces the exact
versions CI uses.

| Path | Use when | Runtime (`voila run`) |
|---|---|---|
| **macOS — devcontainer** | You're on a Mac and want to run `voila run` / `voilad` | Inside the privileged Linux devcontainer (runc + mounts need Linux) |
| **Linux — native** | You're on a Linux box with root + runc | Directly on the host |

> `voila ingest`, the chunk store, and the worker FSM are pure Go and build/test
> anywhere mise runs (incl. macOS native). Only `voila run` / `voilad mount`
> need Linux with `CAP_SYS_ADMIN` (EROFS+NBD by default, FUSE fallback) — which
> is why the macOS path runs them inside the devcontainer.

## What mise manages

`.mise.toml` pins the toolchain; `mise.lock` pins versions + download
checksums across platforms (linux/macOS, amd64/arm64). One command provisions
everything:

```bash
mise install
```

| Tool | Version | Purpose |
|---|---|---|
| `go` | 1.26.2 (matches `go.mod`) | build, vet, test |
| `buf` | 1.71.0 | `make proto` (buf.gen.yaml) |
| `protoc-gen-go` | 1.36.11 | protobuf Go codegen |
| `protoc-gen-go-grpc` | 1.6.2 | protobuf gRPC codegen |

The codegen tools are installed via mise's `go:` backend, so `make proto`
works as soon as `mise install` finishes — no separate `go install` step.

---

## Path 1 — macOS via the devcontainer (recommended for `voila run`)

The devcontainer is a privileged Linux container that gives you runc,
`/dev/fuse`, `/dev/nbd*`, and `CAP_SYS_ADMIN` on a Mac. mise runs **inside** it.

### 1.1 Install mise on the Mac (host)

Only needed once, to make `mise` available if you also want to build/test the
pure-Go parts natively. The devcontainer has its own mise.

```bash
curl -fsSL https://mise.run | sh
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc   # or ~/.zshrc
```

### 1.2 Open the devcontainer

Open the repo in VS Code / GitHub Codespaces — `.devcontainer/devcontainer.json`
already sets `--privileged`. Or run it manually:

```bash
docker run --rm --privileged \
  -v "$PWD:/workspace" -w /workspace \
  mcr.microsoft.com/devcontainers/go:1-bookworm bash
```

### 1.3 Inside the devcontainer: install mise, then `mise install`

```bash
# mise itself
curl -fsSL https://mise.run | sh
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc
eval "$($HOME/.local/bin/mise activate bash)"

# the whole toolchain — versions + checksums come from mise.lock
mise install

# system runtime deps (runc, fuse3, skopeo) — Linux only, apt
apt-get update && apt-get install -y --no-install-recommends runc fuse3 skopeo
# fuse3 + user_allow_other only needed for the FUSE fallback path
grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
```

### 1.4 Build & verify

```bash
make check        # build + go vet + go test ./...
make proto       # regenerate *.pb.go from internal/proto (buf generate)
```

---

## Path 2 — Linux native

For a Linux host (laptop, VM, CI runner) with root and runc. EROFS+NBD is the
default mount backend when the kernel supports it; FUSE is the fallback.

### 2.1 System runtime deps (apt — not managed by mise)

```bash
apt-get update
apt-get install -y --no-install-recommends runc fuse3 skopeo ca-certificates
grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
```

| Dep | Why |
|---|---|
| `runc` | container runtime invoked by `voila run` |
| `fuse3` | FUSE fallback mount path (`/dev/fuse`) when EROFS+NBD is unavailable |
| `skopeo` | daemonless image pulls for e2e fixtures |

### 2.2 Install mise

```bash
curl -fsSL https://mise.run | sh
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.bashrc
echo 'eval "$($HOME/.local/bin/mise activate bash)"' >> ~/.profile
eval "$($HOME/.local/bin/mise activate bash)"
```

### 2.3 Provision the toolchain from the lock file

```bash
mise install     # go 1.26.2 + buf + protoc-gen-go + protoc-gen-go-grpc
```

### 2.4 Build & verify

```bash
go version       # go1.26.2
buf --version    # 1.71.0
make check        # build + go vet + go test ./...
make proto       # regenerate *.pb.go (buf generate)
```

---

## Updating the toolchain

Edit `.mise.toml` (bump a version), then refresh the lock:

```bash
mise install     # install the new versions
mise lock        # rewrite mise.lock with fresh checksums + URLs for all platforms
```

Commit both `.mise.toml` and `mise.lock` together so everyone (and CI) gets the
same pinned, checksum-verified toolchain.

## mise vs apt

- **mise** owns language runtimes and Go-installed CLIs: `go`, `buf`,
  `protoc-gen-go`, `protoc-gen-go-grpc`. These live under
  `~/.local/share/mise/installs/` and are activated per-directory.
- **apt** owns OS-level runtime deps that aren't language runtimes: `runc`,
  `fuse3`, `skopeo`. These stay on the system, not in mise.
