# _env.sh — sourced by every test/gates/gate*.sh right after `set -euo pipefail`.
#
# Source it with:  . "$(dirname "$0")/_env.sh"
#
# The gates run inside a privileged docker container with the repo
# bind-mounted at /workspace from the host. The repo's `.git` directory is
# owned by the host's user; git's "dubious ownership" check (git 2.35.2+,
# April 2022) refuses to operate on a directory owned by a user other than
# the calling process — and the gate runs as root inside the container, so
# the host-uid-owned `.git` is, to git, dubious. Two consequences:
#
#   1. `git status` exits 128 with "fatal: detected dubious ownership in
#      repository at: /workspace".
#   2. Go's default VCS stamping (since Go 1.18) shells out to `git status`
#      to embed vcs.revision / vcs.tag in the build/test binaries; that
#      fails inside the container with
#        error obtaining VCS status: exit status 128
#        Use -buildvcs=false to disable VCS stamping.
#      In current Go this is a hard failure that aborts the build/test.
#
# The gate tests don't consume VCS info (the binaries they build aren't
# the release artifacts, and `internal/version` is reported via `-ldflags
# -X` in `make`/goreleaser, not Go's built-in VCS stamping), so just turn it
# off. `safe.directory` is the belt-and-suspenders: it lets git itself work
# inside the container (useful for any ad-hoc `git status` / `git log` while
# debugging a gate, and for `make`'s `git describe` if anyone runs `make
# build` inside the container — it falls back to `dev` already, but this
# keeps it honest).

git config --global --add safe.directory /workspace 2>/dev/null || true
export GOFLAGS=-buildvcs=false
