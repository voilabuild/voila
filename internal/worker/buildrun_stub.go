//go:build !linux

package worker

import (
	"context"
	"errors"
	"io"

	"voila/internal/chunkstore"
)

// BuildRunSpec is the daemon-side input for a Dockerfile RUN step.
type BuildRunSpec struct {
	RootChunk, ConfigChunk chunkstore.ChunkID
	Argv                   []string
	Env                    []string
	Cwd                    string
	User                   string
	HostNetwork            bool
	Stdin                  io.Reader
}

func (l *platformLauncher) BuildRun(ctx context.Context, spec BuildRunSpec, sink IOSink) (chunkstore.ChunkID, int, error) {
	return chunkstore.ChunkID{}, 0, errors.New("worker: BuildRun requires linux")
}
