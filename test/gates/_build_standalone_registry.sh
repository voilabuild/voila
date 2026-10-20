# _build_standalone_registry.sh — build the in-repo voila-registry server for gate
# scripts after it was removed from the main release line.
#
# The standalone server (cmd/voila-registry + internal/registry/server.go) is
# preserved on branch backup/main-before-go-registry-move. Gate scripts that
# need a local -root registry call build_voila_registry.
#
# Usage (from gate*.sh):
#   . "$(dirname "$0")/_build_standalone_registry.sh"
#   build_voila_registry [/usr/local/bin/voila-registry]

build_voila_registry() {
	local out="${1:-/usr/local/bin/voila-registry}"
	local ref="${VOILA_REGISTRY_SOURCE_REF:-origin/backup/main-before-go-registry-move}"
	local repo_root wt
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	wt="${repo_root}/.cache/gate-voila-registry-worktree"

	if ! git -C "$repo_root" rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
		git -C "$repo_root" fetch --depth 1 origin \
			backup/main-before-go-registry-move:refs/remotes/origin/backup/main-before-go-registry-move \
			|| git -C "$repo_root" fetch origin backup/main-before-go-registry-move
		ref="origin/backup/main-before-go-registry-move"
	fi
	if ! git -C "$repo_root" rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1; then
		echo "ERROR: cannot find voila-registry sources at ${ref}; push backup/main-before-go-registry-move" >&2
		exit 1
	fi

	local want current
	want="$(git -C "$repo_root" rev-parse "${ref}^{commit}")"
	if [ -f "${wt}/cmd/voila-registry/main.go" ]; then
		current="$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")"
	else
		current=""
	fi
	if [ "$current" != "$want" ]; then
		git -C "$repo_root" worktree remove -f "$wt" 2>/dev/null || rm -rf "$wt"
		mkdir -p "$(dirname "$wt")"
		git -C "$repo_root" worktree add -f --detach "$wt" "$want"
	fi

	( cd "$wt" && CGO_ENABLED=0 go build -buildvcs=false -o "$out" ./cmd/voila-registry )
}
