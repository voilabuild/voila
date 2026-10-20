# GOBIN is where `go install` writes the binaries. Prefer `go env GOBIN` (set
# by mise / explicit GOBIN) so the installed binaries land where the toolchain
# actually puts them; fall back to GOPATH/bin. Prepended to PATH below so the
# freshly built voila / voilad shadow any stale copies.
GOBIN := $(shell go env GOBIN)
ifeq ($(GOBIN),)
GOBIN := $(shell go env GOPATH)/bin
endif
export PATH := $(GOBIN):$(PATH)

# Build-time version metadata injected via -ldflags -X into
# voila/internal/version. Mirrors what .goreleaser.yaml stamps at release time
# so a locally-compiled binary (`make build` / `make install`) reports the same
# {version, commit, date} triple a release artifact would. `git describe` falls
# back to "dev" before the first tag (and to the bare SHA in a shallow clone);
# `voila -version` reports `dev (no release build)` in that case.
VERSION := $(shell git describe --tags --dirty=-dirty --always 2>/dev/null || echo dev)
COMMIT  := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
DATE    := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -X 'voila/internal/version.Version=$(VERSION)' -X 'voila/internal/version.Commit=$(COMMIT)' -X 'voila/internal/version.Date=$(DATE)'

.PHONY: proto build test vet check spec

proto:
	buf generate

build:
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS)" ./...

install:
	CGO_ENABLED=0 go install -trimpath -ldflags "$(LDFLAGS)" ./cmd/voila ./cmd/voilad

vet:
	go vet ./...

test:
	CGO_ENABLED=0 go test -tags=testregistry ./...

# spec lints the embedded OpenAPI 3.1 YAML (internal/registry/openapi.yaml)
# with vacuum. Run `mise install` first to provision vacuum, or use
# `go run github.com/daveshanley/vacuum/cmd/vacuum@v0.16.3 lint ...` if
# vacuum is not on PATH.
spec:
	vacuum lint -d internal/registry/openapi.yaml

check: build vet test spec

# --- run targets: start the worker daemon in the background. For a local
# registry server, build voila-registry from branch backup/main-before-go-registry-move
# (see test/gates/_build_standalone_registry.sh). `make install` puts voila /
# voilad on $GOPATH/bin (already on PATH via line 2).
#
# Defaults mirror Docker's layout (and the voila CLI defaults): data root
# /var/lib/voila, worker socket /var/run/voila.sock — both root-owned, so run
# these as root. Override on the command line for a non-root / throwaway
# setup, e.g.
#   make run VOILA_ROOT=/tmp/voila VOILA_SOCKET=/tmp/voila/worker.sock
VOILA_ROOT ?= /var/lib/voila
VOILA_SOCKET ?= /var/run/voila.sock
DAEMON_PID := /tmp/voilad.pid
DAEMON_LOG := /tmp/voilad.log

.PHONY: run-daemon run stop logs-daemon

run-daemon:
	@mkdir -p $(VOILA_ROOT) $(dir $(VOILA_SOCKET))
	@echo "starting voilad (root $(VOILA_ROOT), socket $(VOILA_SOCKET)) — log $(DAEMON_LOG)"
	@nohup voilad -root $(VOILA_ROOT) -socket $(VOILA_SOCKET) > $(DAEMON_LOG) 2>&1 & echo $$! > $(DAEMON_PID)
	@echo "daemon pid $$(cat $(DAEMON_PID))"

run: run-daemon
	@echo "daemon: $$(cat $(DAEMON_PID))"
	@echo "stop with: make stop"

stop:
	@if [ -f $(DAEMON_PID) ]; then kill $$(cat $(DAEMON_PID)) 2>/dev/null || true; rm -f $(DAEMON_PID); fi
	@echo "stopped daemon"

logs-daemon:
	@tail -n 50 -f $(DAEMON_LOG)

# gates: documentation-by-make. Echoes the canonical `docker run --privileged`
# command for each verification gate (see doc/TESTING.md); it does NOT execute
# docker itself — copy/paste the line you need (gates 3/4/5/7 take an alpine
# tarball, gate 6 expects /fixtures/python313.tar + /fixtures/postgres16.tar).
GATE_IMG := mcr.microsoft.com/devcontainers/go:1-bookworm
GATE_VOLS := -v '$(PWD):/workspace' -v /tmp/fixtures:/fixtures -v '$(shell go env GOMODCACHE):/gocache' -e GOMODCACHE=/gocache -w /workspace
.PHONY: gates
gates:
	@echo '# gate 3 — FUSE mount'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate3.sh /fixtures/alpine.tar'
	@echo '# gate 4 — runc runtime'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate4.sh /fixtures/alpine.tar'
	@echo '# gate 5 — worker daemon'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate5.sh /fixtures/alpine.tar'
	@echo '# gate 6 — v0.1 acceptance (needs python313.tar + postgres16.tar; slow — not in CI)'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate6.sh'
	@echo '# gate 7 — lazy cold-start over the network'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate7.sh /fixtures/alpine.tar'
	@echo '# gate 8 — layer reuse + one-file delta push (self-generating fixtures)'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate8.sh'
	@echo '# gate 9 — EROFS+NBD mount backend (opt-in via VOILA_MOUNT_BACKEND=erofs)'
	@echo 'docker run --rm --privileged $(GATE_VOLS) $(GATE_IMG) bash test/gates/gate9.sh /fixtures/alpine.tar'
