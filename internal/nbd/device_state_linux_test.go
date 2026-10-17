//go:build linux

package nbd

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWaitNBDQuiescent(t *testing.T) {
	ctx := context.Background()
	var calls int
	orig := deviceQuiescentHook
	deviceQuiescentHook = func(_ string) bool {
		calls++
		return calls >= 3
	}
	defer func() { deviceQuiescentHook = orig }()

	if err := waitNBDQuiescent(ctx, "/dev/nbd0"); err != nil {
		t.Fatalf("waitNBDQuiescent: %v", err)
	}
	if calls < 3 {
		t.Fatalf("expected polling, calls=%d", calls)
	}
}

func TestWaitNBDQuiescent_Timeout(t *testing.T) {
	orig := deviceQuiescentHook
	deviceQuiescentHook = func(_ string) bool { return false }
	defer func() { deviceQuiescentHook = orig }()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	err := waitNBDQuiescent(ctx, "/dev/nbd0")
	if err == nil {
		t.Fatal("expected timeout")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded, got %v", err)
	}
}
