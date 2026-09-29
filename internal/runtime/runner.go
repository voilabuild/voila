package runtime

import (
	"context"
	"io"
	"syscall"
)

// StdIO bundles the three std streams passed to a runner. The caller wires
// concrete pipes (or os.*) explicitly; nil is honored as /dev/null-style by
// exec.Command, not substituted.
type StdIO struct {
	In  io.Reader
	Out io.Writer
	Err io.Writer
}

// State is a slim projection of `runc state <id>`'s JSON output: the fields a
// caller needs to drive lifecycle decisions.
type State struct {
	ID     string
	Status string
	Pid    int
	Bundle string
}

// Runner is the pluggable container-runtime driver. runc is the default
// (implemented in runc.go); crun / youki substitute by setting
// $VOILA_RUNTIME_BIN.
type Runner interface {
	// Run executes the container FOREGROUND as a direct child; blocks until
	// exit; returns the container process's exit code (0..255). An
	// *exec.ExitError (non-zero container exit) is NOT a failure — the code
	// is returned with a nil error. Only infrastructure failures (binary
	// missing, start failure, non-exit errors) return err.
	//
	// The caller owns signal handling (v0.1); foreground runc forwards its
	// own SIGINT/SIGTERM to the container init, so Run stays simple and does
	// NOT install its own handlers.
	Run(ctx context.Context, id, bundleDir string, io StdIO) (int, error)
	// Kill sends sig to the container's init process via `runc kill`.
	Kill(ctx context.Context, id string, sig syscall.Signal) error
	// State fetches the container's runtime state via `runc state <id>`.
	State(ctx context.Context, id string) (*State, error)
	// Delete removes the container's runtime bookkeeping via
	// `runc delete [--force] <id>`. force must be true if the container is
	// still (nominally) running.
	Delete(ctx context.Context, id string, force bool) error
}
