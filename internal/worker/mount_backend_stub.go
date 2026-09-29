//go:build !linux

package worker

func probeEROFS() (ok bool, reason string) {
	return false, "erofs+nbd requires linux"
}
