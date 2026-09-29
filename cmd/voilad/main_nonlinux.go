// main_nonlinux.go: at runtime we are NOT on Linux.

//go:build !linux

package main

// cliGoos is the runtime GOOS the binary is executing on; on non-Linux it is
// "" so main's onLinux() returns false. The worker internals + FUSE daemon
// are Linux-only by build tag, so main refuses to do anything useful here.
const cliGoos = ""
