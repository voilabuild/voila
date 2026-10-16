//go:build linux

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func mountAndServeZig(out io.Writer, voilaRoot, ref, mountpoint string) error {
	zigBin, ok := findZigFuseBinary()
	if !ok {
		return fmt.Errorf("zig-fuse binary not found (set VOILA_ZIG_FUSE or install zig-fuse on PATH)")
	}
	cmd := exec.Command(zigBin, "serve-store", voilaRoot, ref, mountpoint)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start zig-fuse: %w", err)
	}
	fmt.Fprintf(out, "mounted %s at %s (zig-fuse)\n", ref, mountpoint)

	<-signalsClosed()
	_ = cmd.Process.Signal(syscall.SIGTERM)
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
	_ = exec.Command("fusermount3", "-u", mountpoint).Run()
	fmt.Fprintf(out, "unmounted %s\n", mountpoint)
	return nil
}
