// mount_stub.go provides the mountAndServe hook on non-Linux platforms for
// voilad. The FUSE daemon is Linux-only, so a clear, actionable error is
// returned. main short-circuits non-Linux builds before reaching here; this
// stub exists so the package compiles everywhere.

//go:build !linux

package main

import (
	"io"

	"voila/internal/chunkstore"
)

// mountAndServe refuses the mount with errLinuxOnly so the CLI surfaces a
// clear message on macOS / other non-Linux dev hosts. This hook is never
// reached in practice — main returns "voilad requires linux" before this —
// but it keeps the build green on every platform.
func mountAndServe(out io.Writer, store chunkstore.ChunkStore, rootChunk chunkstore.ChunkID, ref, mountpoint string, allowOther bool) error {
	return errLinuxOnly
}
