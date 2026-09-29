package build

import (
	"context"
	"fmt"
	"io"

	"voila/internal/chunkstore"
	"voila/internal/cli"
	voilapb "voila/internal/proto"
)

// DaemonRunner executes RUN steps via the voilad BuildRun gRPC RPC.
type DaemonRunner struct {
	Socket string
}

// BuildRun implements Runner.
func (d *DaemonRunner) BuildRun(ctx context.Context, spec RunSpec, stdout, stderr io.Writer) (chunkstore.ChunkID, int, error) {
	conn, client, err := cli.DialWorker(d.Socket)
	if err != nil {
		return chunkstore.ChunkID{}, 0, err
	}
	defer conn.Close()

	stream, err := client.BuildRun(ctx)
	if err != nil {
		return chunkstore.ChunkID{}, 0, fmt.Errorf("BuildRun: %w", err)
	}
	if err := stream.Send(&voilapb.BuildRunInput{
		Input: &voilapb.BuildRunInput_Spec{
			Spec: &voilapb.BuildRunSpec{
				RootChunk:   spec.RootChunk[:],
				ConfigChunk: spec.ConfigChunk[:],
				Argv:        spec.Argv,
				Env:         spec.Env,
				Cwd:         spec.Cwd,
				User:        spec.User,
				HostNetwork: true,
			},
		},
	}); err != nil {
		return chunkstore.ChunkID{}, 0, err
	}
	_ = stream.Send(&voilapb.BuildRunInput{Input: &voilapb.BuildRunInput_StdinEof{StdinEof: true}})

	var layer chunkstore.ChunkID
	var exitCode int32
	for {
		out, err := stream.Recv()
		if err != nil {
			return chunkstore.ChunkID{}, 0, err
		}
		switch o := out.Output.(type) {
		case *voilapb.BuildRunOutput_Stdout:
			if stdout != nil {
				_, _ = stdout.Write(o.Stdout)
			}
		case *voilapb.BuildRunOutput_Stderr:
			if stderr != nil {
				_, _ = stderr.Write(o.Stderr)
			}
		case *voilapb.BuildRunOutput_LayerManifestChunk:
			if len(o.LayerManifestChunk) == len(layer) {
				copy(layer[:], o.LayerManifestChunk)
			}
		case *voilapb.BuildRunOutput_ExitCode:
			exitCode = o.ExitCode
			return layer, int(exitCode), nil
		}
	}
}
