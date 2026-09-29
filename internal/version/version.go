// Package version holds the build-time version metadata voila's three
// binaries (voila, voilad, voila-registry) report via a top-level
// `-version`/`--version` flag. The values are injected at link time via
// `-ldflags -X`:
//
//   - the release pipeline (`.goreleaser.yaml` and the `release` workflow)
//     stamps the git tag, the short commit and the build date;
//   - the local `make build`/`make install` recipes derive the same three from
//     git (`git describe`, `git rev-parse`) so a freshly-compiled binary
//     reports a real version too;
//   - a plain `go build` (no `-ldflags` flag at all) leaves the defaults in
//     place, which is why `Version == "dev"` — the binary still runs, it just
//     honestly identifies itself as a non-release build.
//
// All three variables are package-level (linker-overridable) strings on
// purpose: `-X` only works on string vars, and keeping `voila/internal/version`
// free of everything but this metadata means the cmd packages can pull it in
// with zero transitive weight.
package version

import (
	"fmt"
	"runtime"
)

// Version is the release version stamp (e.g. "v0.1.0"). "dev" for a binary
// built without `-ldflags` injection.
var Version = "dev"

// Commit is the short VCS hash the binary was built from, or "" when the
// binary was built without `-ldflags` injection.
var Commit = ""

// Date is the build date (RFC3339, UTC), or "" when the binary was built
// without `-ldflags` injection.
var Date = ""

// String returns a single human-readable version line. The format adapts to
// whether metadata was injected: a locally-built `dev` binary reports
// `dev (no release build)`, while a release binary reports its tag, commit,
// build date and (runtime) OS/arch in one line suitable for a top-level
// `-version` output. OS/arch is the *runtime* platform (runtime.GOOS/GOARCH),
// not the build target — a cross-compiled linux/arm64 binary running on
// linux/arm64 reports `linux/arm64`; the build-target platform is implicit in
// `Version` (only the matching asset runs cleanly anyway).
func String() string {
	if Version == "dev" {
		return "dev (no release build)"
	}
	return fmt.Sprintf("%s (commit %s, built %s, %s/%s)", Version, Commit, Date, runtime.GOOS, runtime.GOARCH)
}
