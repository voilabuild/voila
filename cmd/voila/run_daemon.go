// run_daemon.go contains the daemon-backed half of `voila run`. When a worker
// socket exists and a probe answers, cmdRun dispatches here instead of the
// direct FUSE+runc path in run_linux.go / run_stub.go. The client sends a
// RunSpec, prints the daemon-assigned context id to STDERR (so stdout stays
// clean for the container's own output), pumps os.Stdin → RunInput.stdin,
// demuxes stdout/stderr to cfg's streams, and propagates the container's exit
// code via *exitCodeError just like the direct path.
//
// Ctrl-C on the client side is intercepted: instead of cancelling the stream
// (which would detach but leave the container running) we issue a Kill RPC
// (SIGTERM) for the context and keep streaming until the exit_code frame
// arrives, so the run surfaces the container's actual exit code.

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
)

// runViaDaemon performs `voila run` over the worker daemon. It does not touch
// the FUSE mount or runc directly; the daemon owns the lifecycle. Stdout /
// stderr from the container are written to cfg.Stdout / cfg.Stderr; the
// daemon-assigned context id is printed to errOut. The container's exit code
// is returned through *exitCodeError on non-zero exit (matching the direct
// path's contract with main.run).
func runViaDaemon(cfg Config, socket, query string, cliArgs []string, memoryLimit int64, cpuQuota int, stdout, errOut io.Writer) error {
	conn, client, err := cli.DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()

	ctx := context.Background()
	stream, err := client.Run(ctx)
	if err != nil {
		return fmt.Errorf("dial daemon Run: %w", err)
	}

	// First message: the RunSpec. The worker's Config.Resolve picks the image
	// (mirroring cmd_mount.go's imagestore.Resolve call); the daemon's launcher derives
	// the container argv from the OCI image config via icfg.Argv(cliArgs).
	if err := stream.Send(&voilapb.RunInput{
		Input: &voilapb.RunInput_Spec{
			Spec: &voilapb.RunSpec{
				Image:            query,
				Args:             cliArgs,
				MemoryLimitBytes: memoryLimit,
				CpuQuotaPercent:  int32(cpuQuota),
				AttachStdin:      true,
			},
		},
	}); err != nil {
		return fmt.Errorf("send RunSpec: %w", err)
	}

	// Stdin pump. Reads os.Stdin (blocking) and forwards bytes as
	// RunInput_Stdin frames; EOF closes the send side and emits
	// RunInput_StdinEof. Reads are best-effort: a stream error / process exit
	// mid-pump is tolerated (the goroutine just returns once Send fails). The
	// main goroutine does not block on stdinDone so the user is not kept
	// waiting on a slow TTY; the pump collapses at process exit.
	stdinDone := make(chan struct{})
	go func() {
		defer close(stdinDone)
		pumpStdinToRun(stream, os.Stdin)
	}()

	// SIGINT / SIGTERM on the client side: intercept and issue a Kill RPC for
	// the context. The receive loop keeps running until the exit_code frame
	// arrives so we still surface the container's actual exit code (otherwise
	// a SIGTERM'd container still sends an exit_code frame). ctxID is written
	// by the receive loop and read by the signal goroutine → atomic.
	var ctxIDAtomic atomic.Value // string
	ctxIDAtomic.Store("")
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	go func() {
		_, ok := <-sigCh
		if !ok {
			return
		}
		id, _ := ctxIDAtomic.Load().(string)
		if id == "" {
			// No context id yet — nothing to kill. The server will eventually
			// surface whatever happens (or a stream error close).
			return
		}
		killCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_, _ = client.Kill(killCtx, &voilapb.KillRequest{ContextId: id, Signal: 0})
	}()

	// Receive loop: first frame is the context id, then stdout/stderr, then
	// an optional Stats frame, then a terminal exit_code frame. Other
	// message types are ignored (forward-compatible: proto3 oneof).
	var stats *voilapb.FetchStats
	var exitCode int32
	var gotExit bool
	for {
		msg, err := stream.Recv()
		if err != nil {
			if err == io.EOF {
				if !gotExit {
					return errors.New("voila: daemon stream closed without exit frame")
				}
				break
			}
			_ = stream.CloseSend()
			return fmt.Errorf("daemon stream: %w", err)
		}
		switch out := msg.GetOutput().(type) {
		case *voilapb.RunOutput_ContextId:
			ctxIDAtomic.Store(out.ContextId)
			fmt.Fprintf(errOut, "context: %s\n", out.ContextId)
		case *voilapb.RunOutput_Stdout:
			if len(out.Stdout) > 0 {
				_, _ = stdout.Write(out.Stdout)
			}
		case *voilapb.RunOutput_Stderr:
			if len(out.Stderr) > 0 {
				_, _ = errOut.Write(out.Stderr)
			}
		case *voilapb.RunOutput_Stats:
			stats = out.Stats
		case *voilapb.RunOutput_ExitCode:
			exitCode = out.ExitCode
			gotExit = true
			_ = stream.CloseSend()
			break
		}
		if gotExit {
			break
		}
	}

	// Print the per-run fetch stats line to stderr (stdout must stay exactly
	// the container's own output). Omit when the daemon did not send a
	// Stats frame (e.g. an old daemon) or the frame is zero with no totals.
	if stats != nil {
		if line := formatFetchedLine(stats); line != "" {
			fmt.Fprintln(errOut, line)
		}
	}

	// Best-effort: nudge the stdin pump to stop. Closing the stream cancels
	// any in-flight Send; the goroutine returns on the next os.Stdin read or
	// a Send error. We do not block on stdinDone here so the user is not kept
	// waiting on a slow TTY.
	_ = stream.CloseSend()
	go func() { <-stdinDone }()

	if gotExit && exitCode != 0 {
		return &exitCodeError{Code: int(exitCode)}
	}
	return nil
}

// pumpStdinToRun forwards bytes from r to the stream as RunInput_Stdin frames.
// On read EOF it sends RunInput_StdinEof. On a Send error (stream gone) it
// returns; the goroutine caller does not require a specific outcome.
func pumpStdinToRun(stream voilapb.Worker_RunClient, r io.Reader) {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			serr := stream.Send(&voilapb.RunInput{
				Input: &voilapb.RunInput_Stdin{Stdin: append([]byte(nil), buf[:n]...)},
			})
			if serr != nil {
				return
			}
		}
		if err != nil {
			if err == io.EOF {
				_ = stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_StdinEof{StdinEof: true}})
			}
			return
		}
	}
}

// formatFetchedLine renders the per-run fetch-stats line:
//
//	fetched: <chunks> chunks / <human bytes> (<pct> of <total> chunks, <pct> of <human total>)
//
// The parenthetical is omitted when the image totals are 0 (unknown). An empty
// string is returned when the stats frame carries nothing meaningful (no
// counter / zero deltas with no totals), so the run path stays quiet on plain
// no-op launches.
//
// Percentages render with one decimal. Used by both daemon and direct run
// paths; formatBytes is the existing human-bytes helper in images.go.
func formatFetchedLine(s *voilapb.FetchStats) string {
	if s == nil {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "fetched: %d chunks / %s", s.GetChunksFetched(), cli.FormatBytes(s.GetBytesFetched()))
	totalChunks := s.GetImageChunks()
	totalBytes := s.GetImageBytes()
	if totalChunks == 0 && totalBytes == 0 {
		return b.String()
	}
	b.WriteString(" (")
	wrote := false
	if totalChunks > 0 {
		fmt.Fprintf(&b, "%s of %d chunks", pct(s.GetChunksFetched(), totalChunks), totalChunks)
		wrote = true
	}
	if totalBytes > 0 {
		if wrote {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%s of %s", pct(s.GetBytesFetched(), totalBytes), cli.FormatBytes(totalBytes))
	}
	b.WriteString(")")
	return b.String()
}

// pct renders the percentage of part/total with one decimal, clamping the
// denominator at 1 to avoid divide-by-zero (callers guard the zero case but
// this is defensively safe). total of 0 → "0.0%".
func pct(part, total uint64) string {
	if total == 0 {
		return "0.0%"
	}
	return fmt.Sprintf("%.1f%%", float64(part)/float64(total)*100.0)
}
