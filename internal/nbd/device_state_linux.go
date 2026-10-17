//go:build linux

package nbd

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	nbdSetupTimeout    = 15 * time.Second
	nbdTeardownTimeout = 10 * time.Second
)

func nbdBlockName(devPath string) string {
	name := devPath
	if i := strings.LastIndex(devPath, "/"); i >= 0 {
		name = devPath[i+1:]
	}
	return name
}

func nbdPIDPresent(devPath string) bool {
	pidPath := "/sys/block/" + nbdBlockName(devPath) + "/pid"
	b, err := os.ReadFile(pidPath)
	return err == nil && len(strings.TrimSpace(string(b))) > 0
}

// deviceQuiescentHook is set by tests to inject quiescence checks.
var deviceQuiescentHook func(devPath string) bool

// deviceQuiescent reports whether the kernel has no active NBD session on devPath
// (pid gone and sysfs size back to zero).
func deviceQuiescent(devPath string) bool {
	if deviceQuiescentHook != nil {
		return deviceQuiescentHook(devPath)
	}
	if nbdPIDPresent(devPath) {
		return false
	}
	got, err := readDeviceSizeSysfs(devPath)
	if err != nil {
		return false
	}
	return got == 0
}

func waitNBDQuiescent(ctx context.Context, devPath string) error {
	for {
		if deviceQuiescent(devPath) {
			return nil
		}
		select {
		case <-ctx.Done():
			got, _ := readDeviceSizeSysfs(devPath)
			pid := nbdPIDPresent(devPath)
			return fmt.Errorf("nbd: %s not quiescent (pid=%v size=%d bytes): %w", devPath, pid, got, ctx.Err())
		case <-time.After(nbdPollInterval):
		}
	}
}
