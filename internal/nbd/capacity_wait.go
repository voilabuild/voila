package nbd

import (
	"context"
	"fmt"
	"time"
)

const nbdPollInterval = 100 * time.Microsecond

// deviceSizeReader returns the block device's size in bytes.
type deviceSizeReader func() (uint64, error)

// exportSizeReady reports whether gotBytes (from sysfs×512 or BLKGETSIZE64) covers
// the negotiated export size. Sysfs is in 512-byte sectors (e.g. 8 sectors = 4096 B).
func exportSizeReady(wantBytes, gotBytes uint64) bool {
	if wantBytes == 0 {
		return true
	}
	if gotBytes >= wantBytes {
		return true
	}
	wantSectors := (wantBytes + 511) / 512
	gotSectors := gotBytes / 512
	return gotSectors >= wantSectors
}

// waitDeviceCapacity polls until read reports at least wantBytes, or ctx expires.
func waitDeviceCapacity(ctx context.Context, wantBytes uint64, read deviceSizeReader) error {
	if wantBytes == 0 {
		return nil
	}
	for {
		got, err := read()
		if err == nil && exportSizeReady(wantBytes, got) {
			return nil
		}
		select {
		case <-ctx.Done():
			if err != nil {
				return fmt.Errorf("nbd: device capacity %d bytes not ready: %v: %w", wantBytes, err, ctx.Err())
			}
			if got < wantBytes {
				return fmt.Errorf("nbd: device capacity %d bytes not ready (got %d): %w", wantBytes, got, ctx.Err())
			}
			return fmt.Errorf("nbd: device capacity %d bytes not ready: %w", wantBytes, ctx.Err())
		case <-time.After(nbdPollInterval):
		}
	}
}
