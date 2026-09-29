// launch_stub.go is the non-Linux counterpart to launch_linux.go. The actual
// mount+runc launch path requires the Linux kernel (mount.Mount is linux-only
// and runc is unavailable on macOS), so on every other platform the platform
// Launcher refuses immediately with a clear error. OS-independent service
// tests substitute a fake Launcher at the Worker level (see worker_test.go).

//go:build !linux

package worker

import (
	"context"
	"errors"
	"syscall"
)

// errLinuxOnly is the sentinel error returned by the stub launcher. It
// surfaces the same actionable message on macOS / other dev hosts as
// cmd/voila's run_stub / mount_stub.
var errLinuxOnly = errors.New("voila run/logs/exec require linux (run inside the devcontainer)")

// platformLauncher is the no-op platform Launcher used when voila is built on
// a non-Linux host. Every method returns errLinuxOnly; the Worker still
// creates and registers contexts so the gRPC plumbing (FSM, ring buffer,
// events) is exercised, but the actual launch is rejected.
type platformLauncher struct{}

// Launch implements Launcher.
func (platformLauncher) Launch(context.Context, LaunchSpec, IOSink) (int, error) {
	return 0, errLinuxOnly
}

// Exec implements Launcher.
func (platformLauncher) Exec(context.Context, string, ExecSpec, IOSink) (int, error) {
	return 0, errLinuxOnly
}

// Kill implements Launcher.
func (platformLauncher) Kill(context.Context, string, syscall.Signal) error {
	return errLinuxOnly
}

// defaultPlatformLauncher returns the platform Launcher for Config on
// non-Linux hosts (the no-op stub). Mirrored on Linux by launch_linux.go's
// newPlatformLauncher.
func defaultPlatformLauncher(cfg Config) Launcher {
	_ = cfg
	return platformLauncher{}
}
