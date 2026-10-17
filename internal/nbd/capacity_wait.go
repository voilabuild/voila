package nbd

import (
	"context"
	"fmt"
	"time"
)

// deviceSizeReader returns the block device's size in bytes.
type deviceSizeReader func() (uint64, error)

// waitDeviceCapacity polls until read reports at least wantBytes, or ctx expires.
func waitDeviceCapacity(ctx context.Context, wantBytes uint64, read deviceSizeReader) error {
	if wantBytes == 0 {
		return nil
	}
	for {
		got, err := read()
		if err == nil && got >= wantBytes {
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
		case <-time.After(time.Millisecond):
		}
	}
}
