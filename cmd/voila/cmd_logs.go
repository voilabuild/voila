// cmd_logs.go implements `voila logs [-follow] <ctx-id>`: replays the
// context's ring buffer (and, with -follow, streams new chunks until the
// context finishes). A reachable daemon is required.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
)

// cmdLogs implements `voila logs [-follow] <ctx-id> [-root dir]`. Writes each
// LogChunk whose stderr flag is false to stdout; whose flag is true to
// stderr. -follow keeps the stream open after replay, mirroring `tail -f`.
func cmdLogs(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "logs", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
		follow     bool
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	fs.BoolVar(&follow, "follow", false, "after replay, stream new chunks until the context finishes")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila logs [-follow] <ctx-id> [-root dir] [-socket path]")
	}
	ctxID := fs.Arg(0)
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	out := cfg.Stdout
	if out == nil {
		out = os.Stdout
	}
	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}

	conn, client, err := cli.DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()

	stream, err := client.Logs(context.Background(), &voilapb.LogsRequest{ContextId: ctxID, Follow: follow})
	if err != nil {
		return fmt.Errorf("logs: %w", err)
	}
	return demuxLogs(stream, out, errOut)
}

// logsStream is the minimal Recv contract a Worker_LogsClient offers; it is
// factored out as an interface so the demux logic is testable in isolation
// with a canned set of chunks (no daemon needed).
type logsStream interface {
	Recv() (*voilapb.LogChunk, error)
}

// demuxLogs writes each chunk from stream to stdout (stderr flag false) or
// stderr (stderr flag true) until the stream returns io.EOF. Empty-payload
// chunks are skipped (they carry no data and are noise on the wire anyway).
func demuxLogs(stream logsStream, stdout, stderr io.Writer) error {
	for {
		chunk, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("logs: %w", err)
		}
		if len(chunk.GetData()) == 0 {
			continue
		}
		if chunk.GetStderr() {
			_, _ = stderr.Write(chunk.GetData())
		} else {
			_, _ = stdout.Write(chunk.GetData())
		}
	}
}
