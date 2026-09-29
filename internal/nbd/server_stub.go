// server_stub.go is the non-Linux counterpart to server_linux.go. The NBD
// device + EROFS mount path requires the Linux kernel (/dev/nbd*, the NBD
// ioctls, the EROFS filesystem), so on every other platform the package
// exposes a no-op Registry so it still builds for `make check`. The EROFS
// adapter itself (internal/erofsadapter) is darwin-runnable; only the NBD
// device plumbing is Linux-only.

//go:build !linux

package nbd

import (
	"context"
	"errors"

	"voila/internal/chunkstore"
	"voila/internal/erofsadapter"
)

// errLinuxOnly is the sentinel error returned by the stub Registry.
var errLinuxOnly = errors.New("nbd: requires linux (NBD device + EROFS mount)")

// Device is a no-op placeholder on non-Linux.
type Device struct{}

// Path returns an empty path (unused on non-Linux).
func (d *Device) Path() string { return "" }

// Registry is a no-op registry on non-Linux.
type Registry struct{}

// NewRegistry returns a no-op registry on non-Linux.
func NewRegistry() *Registry { return &Registry{} }

// Acquire always fails on non-Linux.
func (r *Registry) Acquire(ctx context.Context, key string, result *erofsadapter.BuildResult, store chunkstore.ChunkStore) (*Device, error) {
	return nil, errLinuxOnly
}

// Release is a no-op on non-Linux.
func (r *Registry) Release(key string) {}

// HasFreeDevice is always false off Linux.
func HasFreeDevice() bool { return false }
