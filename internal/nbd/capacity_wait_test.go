package nbd

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWaitDeviceCapacity(t *testing.T) {
	ctx := context.Background()
	var calls int
	read := func() (uint64, error) {
		calls++
		if calls < 3 {
			return 0, nil
		}
		return 8192, nil
	}
	if err := waitDeviceCapacity(ctx, 4096, read); err != nil {
		t.Fatalf("waitDeviceCapacity: %v", err)
	}
	if calls < 3 {
		t.Fatalf("expected polling, calls=%d", calls)
	}
}

func TestWaitDeviceCapacity_ZeroWant(t *testing.T) {
	ctx := context.Background()
	if err := waitDeviceCapacity(ctx, 0, func() (uint64, error) {
		t.Fatal("read should not be called for zero want")
		return 0, nil
	}); err != nil {
		t.Fatalf("waitDeviceCapacity: %v", err)
	}
}

func TestWaitDeviceCapacity_Timeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := waitDeviceCapacity(ctx, 4096, func() (uint64, error) {
		return 0, nil
	})
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded, got %v", err)
	}
}

func TestWaitDeviceCapacity_ReadErrorThenReady(t *testing.T) {
	ctx := context.Background()
	var calls int
	read := func() (uint64, error) {
		calls++
		if calls == 1 {
			return 0, errors.New("transient")
		}
		return 4096, nil
	}
	if err := waitDeviceCapacity(ctx, 4096, read); err != nil {
		t.Fatalf("waitDeviceCapacity: %v", err)
	}
}
