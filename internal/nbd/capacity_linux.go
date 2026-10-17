//go:build linux

package nbd

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const blkGetSize64 = 0x80081272 // _IOR(0x12, 114, size_t)

func readDeviceSizeBytes(devPath string) (uint64, error) {
	// Sysfs size can lag behind BLKGETSIZE64 right after NBD_DO_IT (especially
	// for small exports like 4096 bytes / 8 sectors). Treat sysfs==0 as unknown.
	if n, err := readDeviceSizeSysfs(devPath); err == nil && n > 0 {
		return n, nil
	}
	f, err := os.Open(devPath)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return readDeviceSizeBLK(f.Fd())
}

func readDeviceSizeSysfs(devPath string) (uint64, error) {
	name := devPath
	if i := strings.LastIndex(devPath, "/"); i >= 0 {
		name = devPath[i+1:]
	}
	b, err := os.ReadFile("/sys/block/" + name + "/size")
	if err != nil {
		return 0, err
	}
	sectors, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	if err != nil {
		return 0, err
	}
	return sectors * 512, nil
}

func readDeviceSizeBLK(fd uintptr) (uint64, error) {
	var size uint64
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, uintptr(blkGetSize64), uintptr(unsafe.Pointer(&size)))
	if errno != 0 {
		return 0, fmt.Errorf("BLKGETSIZE64: %w", errno)
	}
	return size, nil
}
