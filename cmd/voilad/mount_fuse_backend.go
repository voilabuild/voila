// mount_fuse_backend.go selects go-fuse vs zig-fuse for `voilad mount` on Linux.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	fuseBackendGo  = "go"
	fuseBackendZig = "zig"
)

// resolveMountFuseBackend picks the FUSE userspace server for voilad mount.
// VOILA_MOUNT_FUSE: auto (default), go, or zig. VOILA_ZIG_FUSE sets the zig-fuse binary path.
func resolveMountFuseBackend(env string, zigFinder func() (string, bool)) (name, reason string) {
	switch strings.ToLower(strings.TrimSpace(env)) {
	case "go", "gofuse":
		return fuseBackendGo, "VOILA_MOUNT_FUSE=go"
	case "zig":
		if _, ok := zigFinder(); ok {
			return fuseBackendZig, "VOILA_MOUNT_FUSE=zig"
		}
		return fuseBackendGo, "VOILA_MOUNT_FUSE=zig but zig-fuse binary not found, using go-fuse"
	case "", "auto":
		if p, ok := zigFinder(); ok {
			return fuseBackendZig, "zig-fuse at " + p
		}
		return fuseBackendGo, "zig-fuse not found"
	default:
		return fuseBackendGo, fmt.Sprintf("unknown VOILA_MOUNT_FUSE=%q, using go-fuse", env)
	}
}

func findZigFuseBinary() (string, bool) {
	if p := strings.TrimSpace(os.Getenv("VOILA_ZIG_FUSE")); p != "" {
		if isExecFile(p) {
			return p, true
		}
		return "", false
	}
	if p, err := exec.LookPath("zig-fuse"); err == nil && isExecFile(p) {
		return p, true
	}
	if exe, err := os.Executable(); err == nil {
		cand := filepath.Join(filepath.Dir(exe), "zig-fuse")
		if isExecFile(cand) {
			return cand, true
		}
	}
	return "", false
}

func isExecFile(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	if st.IsDir() {
		return false
	}
	return st.Mode()&0o111 != 0
}
