// cmd_exec.go implements `voila exec <ctx-id> [--] <cmd...>`: launches an
// additional process inside a running context via the daemon's Exec RPC. The
// stream discipline mirrors `voila run`: send ExecSpec, pump stdin, demux
// stdout/stderr, terminate on exit_code. Requires a running daemon
//
// (the daemon is the only thing that can talk to a container's namespaces).
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

// cmdExec implements `voila exec <ctx-id> [--] <cmd...> [-root dir]`. A
// reachable daemon is required. The "--" separator is stripped like `voila
// run` so a command whose argv[0] is a flag-looking path still parses.
func cmdExec(cfg Config, args []string) error {
	fs := cli.NewFlagSet("voila", "exec", cfg.Stderr)
	var (
		rootFlag   string
		socketFlag string
	)
	fs.StringVar(&rootFlag, "root", "", "voila data root directory (default: $VOILA_ROOT or /var/lib/voila)")
	fs.StringVar(&socketFlag, "socket", "", "worker socket path (default: $VOILA_SOCKET or /var/run/voila.sock)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() < 2 {
		return errors.New("usage: voila exec <ctx-id> [--] <cmd...> [-root dir] [-socket path]")
	}
	ctxID := fs.Arg(0)
	cmdArgs := fs.Args()[1:]
	// flag parsing stops at the first positional, so a "--" before cmdArgs is
	// NOT consumed by fs.Parse — strip it here so it does not become argv[0].
	cmdArgs = stripLeadingDashDash(cmdArgs)
	if len(cmdArgs) == 0 {
		return errors.New("usage: voila exec <ctx-id> [--] <cmd...> [-root dir] [-socket path]")
	}
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
	return execViaDaemon(cfg, socket, ctxID, cmdArgs, out, errOut)
}

// execViaDaemon performs the Exec RPC over the daemon and demuxes its output
// streams. The exit-code propagation contract matches cmdRun: a non-zero
// container exit surfaces as *exitCodeError (silent in main.run).
func execViaDaemon(_ Config, socket, ctxID string, cmdArgs []string, stdout, errOut io.Writer) error {
	conn, client, err := cli.DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()

	ctx := context.Background()
	stream, err := client.Exec(ctx)
	if err != nil {
		return fmt.Errorf("dial daemon Exec: %w", err)
	}

	if err := stream.Send(&voilapb.ExecInput{
		Input: &voilapb.ExecInput_Spec{
			Spec: &voilapb.ExecSpec{
				ContextId:   ctxID,
				Args:        cmdArgs,
				AttachStdin: true,
			},
		},
	}); err != nil {
		return fmt.Errorf("send ExecSpec: %w", err)
	}

	// Stdin pump, mirroring runViaDaemon.
	stdinDone := make(chan struct{})
	go func() {
		defer close(stdinDone)
		pumpStdinToExec(stream, os.Stdin)
	}()

	var exitCode int32
	var gotExit bool
	for {
		msg, rerr := stream.Recv()
		if rerr != nil {
			if rerr == io.EOF {
				if !gotExit {
					return errors.New("voila: daemon stream closed without exit frame")
				}
				break
			}
			_ = stream.CloseSend()
			return fmt.Errorf("daemon stream: %w", rerr)
		}
		switch out := msg.GetOutput().(type) {
		case *voilapb.ExecOutput_Stdout:
			if len(out.Stdout) > 0 {
				_, _ = stdout.Write(out.Stdout)
			}
		case *voilapb.ExecOutput_Stderr:
			if len(out.Stderr) > 0 {
				_, _ = errOut.Write(out.Stderr)
			}
		case *voilapb.ExecOutput_ExitCode:
			exitCode = out.ExitCode
			gotExit = true
			_ = stream.CloseSend()
		}
		if gotExit {
			break
		}
	}
	go func() { <-stdinDone }()
	if gotExit && exitCode != 0 {
		return &exitCodeError{Code: int(exitCode)}
	}
	return nil
}

// pumpStdinToExec mirrors pumpStdinToRun for the Exec stream shape.
func pumpStdinToExec(stream voilapb.Worker_ExecClient, r io.Reader) {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			serr := stream.Send(&voilapb.ExecInput{
				Input: &voilapb.ExecInput_Stdin{Stdin: append([]byte(nil), buf[:n]...)},
			})
			if serr != nil {
				return
			}
		}
		if err != nil {
			if err == io.EOF {
				_ = stream.Send(&voilapb.ExecInput{Input: &voilapb.ExecInput_StdinEof{StdinEof: true}})
			}
			return
		}
	}
}
