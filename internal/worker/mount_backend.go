package worker

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

const (
	backendFUSE  = "fuse"
	backendEROFS = "erofs"
)

var (
	backendOnce sync.Once
	backendName string
	backendWhy  string
)

// MountBackend returns the mount backend this process will use ("fuse" or
// "erofs"). The first call resolves it: an explicit VOILA_MOUNT_BACKEND
// wins; otherwise the daemon probes for EROFS chunk-based support (Linux
// 5.15+), the erofs filesystem, and a free /dev/nbd*, and falls back to
// FUSE when anything is missing.
func MountBackend() string {
	pickMountBackend()
	return backendName
}

// MountBackendReason is a short phrase for the daemon log line, e.g.
// "erofs+nbd ready" or "no usable /dev/nbd*".
func MountBackendReason() string {
	pickMountBackend()
	return backendWhy
}

func mountBackend() string { return MountBackend() }

func pickMountBackend() {
	backendOnce.Do(func() {
		backendName, backendWhy = resolveMountBackend(os.Getenv("VOILA_MOUNT_BACKEND"))
	})
}

// resolveMountBackend is the pure decision: env override, else probe.
func resolveMountBackend(env string) (name, reason string) {
	return resolveMountBackendWith(env, probeEROFS)
}

func resolveMountBackendWith(env string, probe func() (ok bool, reason string)) (name, reason string) {
	switch strings.ToLower(strings.TrimSpace(env)) {
	case backendFUSE:
		return backendFUSE, "VOILA_MOUNT_BACKEND=fuse"
	case backendEROFS:
		return backendEROFS, "VOILA_MOUNT_BACKEND=erofs"
	case "", "auto":
		ok, why := probe()
		if ok {
			return backendEROFS, why
		}
		return backendFUSE, why
	default:
		return backendFUSE, fmt.Sprintf("unknown VOILA_MOUNT_BACKEND=%q, using fuse", env)
	}
}

// kernelReleaseAtLeast parses a uname release (e.g. "5.15.0-91-generic")
// and reports whether it is at least maj.min. Unparseable strings are false.
func kernelReleaseAtLeast(release string, maj, min int) bool {
	gotMaj, gotMin, ok := parseKernelRelease(release)
	if !ok {
		return false
	}
	if gotMaj != maj {
		return gotMaj > maj
	}
	return gotMin >= min
}

func parseKernelRelease(release string) (maj, min int, ok bool) {
	release = strings.TrimSpace(release)
	if release == "" {
		return 0, 0, false
	}
	// Take leading "MAJOR.MINOR"; ignore -distro suffixes.
	parts := strings.SplitN(release, ".", 3)
	if len(parts) < 2 {
		return 0, 0, false
	}
	maj, err := strconv.Atoi(leadingDigits(parts[0]))
	if err != nil {
		return 0, 0, false
	}
	min, err = strconv.Atoi(leadingDigits(parts[1]))
	if err != nil {
		return 0, 0, false
	}
	return maj, min, true
}

func leadingDigits(s string) string {
	i := 0
	for i < len(s) && unicode.IsDigit(rune(s[i])) {
		i++
	}
	return s[:i]
}

// filesystemsHas reports whether /proc/filesystems-style text lists name
// as a filesystem (token match, so "erofs" does not match "erofsfoo").
func filesystemsHas(data, name string) bool {
	for _, field := range strings.Fields(data) {
		if field == name {
			return true
		}
	}
	return false
}
