// main_linux.go: at runtime we are on Linux.

//go:build linux

package main

// cliGoos is the runtime GOOS the binary is executing on; on linux it is
// "linux". main reports the daemon requires linux when this is not "linux".
const cliGoos = "linux"
