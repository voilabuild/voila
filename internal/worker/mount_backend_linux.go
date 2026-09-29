//go:build linux

package worker

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"voila/internal/nbd"
)

// probeEROFS reports whether this host can run the EROFS+NBD backend.
// Best-effort modprobe is attempted (the daemon is already privileged);
// missing modules or device nodes fall through to FUSE.
func probeEROFS() (ok bool, reason string) {
	rel := unameRelease()
	if !kernelReleaseAtLeast(rel, 5, 15) {
		if rel == "" {
			return false, "could not read kernel release"
		}
		return false, fmt.Sprintf("kernel %s < 5.15 (need EROFS chunk-based inodes)", rel)
	}
	_ = exec.Command("modprobe", "erofs").Run()
	_ = exec.Command("modprobe", "nbd").Run()
	data, err := os.ReadFile("/proc/filesystems")
	if err != nil || !filesystemsHas(string(data), "erofs") {
		return false, "erofs filesystem not available"
	}
	if !nbd.HasFreeDevice() {
		return false, "no usable /dev/nbd*"
	}
	return true, "erofs+nbd ready"
}

func unameRelease() string {
	var uts syscall.Utsname
	if err := syscall.Uname(&uts); err != nil {
		return ""
	}
	return utsCString(uts.Release[:])
}

func utsCString[T ~int8 | ~uint8](v []T) string {
	b := make([]byte, 0, len(v))
	for _, c := range v {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}
