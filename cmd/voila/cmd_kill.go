// cmd_kill.go implements `voila kill [-signal N] <ctx-id>`: signals a running
// context via the daemon's Kill RPC. Requires a daemon. The default signal is
// SIGTERM (signal 0 in the wire maps to SIGTERM per the proto comment).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
)

// cmdKill implements `voila kill [-signal N] <ctx-id> [-root dir]`.
//
// The `-signal` flag accepts a positive integer signal number which is sent
// to the container's init process via the daemon's Kill RPC. 0 (the default)
// is treated by the worker as SIGTERM per worker.proto.
func cmdKill(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "kill", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
		signalNum  int
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	fs.IntVar(&signalNum, "signal", 0, "signal number to send (0 = SIGTERM)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: voila kill [-signal N] <ctx-id> [-root dir] [-socket path]")
	}
	ctxID := fs.Arg(0)
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)

	errOut := cfg.Stderr
	if errOut == nil {
		errOut = os.Stderr
	}

	conn, client, err := cli.DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()

	if _, err := client.Kill(context.Background(), &voilapb.KillRequest{ContextId: ctxID, Signal: int32(signalNum)}); err != nil {
		return fmt.Errorf("kill: %w", err)
	}
	fmt.Fprintf(errOut, "signalled %s\n", ctxID)
	return nil
}
