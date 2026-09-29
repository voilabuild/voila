package version

import (
	"runtime"
	"strings"
	"testing"
)

// setVars replaces the package vars for the duration of the test and restores
// them on cleanup. The `-ldflags` path mutates these at link time; tests can
// reach the same state from the inside.
func setVars(t *testing.T, v, commit, date string) {
	t.Helper()
	oV, oC, oD := Version, Commit, Date
	t.Cleanup(func() { Version, Commit, Date = oV, oC, oD })
	Version, Commit, Date = v, commit, date
}

func TestStringDev(t *testing.T) {
	setVars(t, "dev", "", "")
	if got := String(); got != "dev (no release build)" {
		t.Fatalf("dev String() = %q, want %q", got, "dev (no release build)")
	}
}

func TestStringRelease(t *testing.T) {
	setVars(t, "v0.1.0", "d7c2f02abc", "2026-07-03T22:50:00Z")
	got := String()
	for _, want := range []string{"v0.1.0", "d7c2f02abc", "2026-07-03T22:50:00Z"} {
		if !strings.Contains(got, want) {
			t.Fatalf("release String() = %q, want contains %q", got, want)
		}
	}
	if want := runtime.GOOS + "/" + runtime.GOARCH; !strings.Contains(got, want) {
		t.Fatalf("release String() = %q, want contains <GOOS>/<GOARCH> %q", got, want)
	}
	if strings.Contains(got, "commit ,") || strings.Contains(got, "built ,") {
		t.Fatalf("release String() = %q, want no empty field in the release form", got)
	}
}

func TestStringDefaultDev(t *testing.T) {
	// Without setVars the package defaults apply: "dev" with no commit/date.
	// Guard against an accidental future default change that would silently
	// flip a freshly-built `go build` binary into the release format.
	if got := String(); !strings.HasPrefix(got, "dev") {
		t.Fatalf("default String() = %q, want starts with \"dev\"", got)
	}
}
