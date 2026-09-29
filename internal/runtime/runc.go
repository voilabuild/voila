package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// runcBinEnv is the environment variable that overrides the runc binary path.
const runcBinEnv = "VOILA_RUNTIME_BIN"

// defaultRuncBin is the binary looked up on $PATH when no override is set.
const defaultRuncBin = "runc"

// runcRunner drives an OCI runtime binary (runc by default; crun/youki via
// $VOILA_RUNTIME_BIN) in the foreground. It implements Runner.
type runcRunner struct {
	bin string
}

// NewRunc returns a Runner backed by the runc/crun/youki binary. The binary
// name resolves from $VOILA_RUNTIME_BIN, defaulting to "runc" (looked up on
// $PATH).
func NewRunc() Runner {
	return &runcRunner{bin: runcBinary()}
}

// runcBinary returns the OCI runtime binary to invoke, resolving
// $VOILA_RUNTIME_BIN with the same default ("runc") as NewRunc. Factored out
// so the ExecProcess helper (which is a package-level entry point rather than
// a Runner interface method) shares the same resolution.
func runcBinary() string {
	bin := os.Getenv(runcBinEnv)
	if bin == "" {
		bin = defaultRuncBin
	}
	return bin
}

// Run executes the container FOREGROUND as a direct child; blocks until exit;
// returns the container process's exit code (0..255). A non-zero container
// exit (an *exec.ExitError) is NOT a failure — its code is returned with a
// nil error. Only infrastructure failures (binary missing, start failure,
// non-exit errors) return err.
//
// The caller owns signal handling (v0.1); foreground runc forwards its own
// SIGINT/SIGTERM to the container init, so this method does NOT install its
// own handlers.
func (r *runcRunner) Run(ctx context.Context, id, bundleDir string, io StdIO) (int, error) {
	if id == "" {
		return 0, errors.New("runtime: container id is required")
	}
	if bundleDir == "" {
		return 0, errors.New("runtime: bundle dir is required")
	}
	cmd := exec.CommandContext(ctx, r.bin, "run", "--bundle", bundleDir, id)
	if io.In != nil {
		cmd.Stdin = io.In
	}
	if io.Out != nil {
		cmd.Stdout = io.Out
	}
	if io.Err != nil {
		cmd.Stderr = io.Err
	}

	if err := cmd.Start(); err != nil {
		// Binary missing or fork failure — infrastructure error.
		return 0, fmt.Errorf("runtime: start %q: %w", r.bin, err)
	}
	err := cmd.Wait()
	if err == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		// Non-zero container exit: extract the code, return nil error.
		return exitErr.ExitCode(), nil
	}
	// Non-exit error (signal, ctx cancellation surfaced as a non-exit
	// error, etc.) — infrastructure failure.
	return 0, fmt.Errorf("runtime: wait %q: %w", r.bin, err)
}

// Kill sends sig to the container's init. The signal is rendered by name
// (runc kill takes a signal name or number; names work cross-platform-ish).
func (r *runcRunner) Kill(ctx context.Context, id string, sig syscall.Signal) (err error) {
	if id == "" {
		return errors.New("runtime: container id is required")
	}
	return r.runCapture(ctx, "kill", id, r.sigName(sig))
}

// Delete removes the container's runtime bookkeeping. force must be true if
// the container is still (nominally) running.
func (r *runcRunner) Delete(ctx context.Context, id string, force bool) error {
	if id == "" {
		return errors.New("runtime: container id is required")
	}
	args := []string{"delete"}
	if force {
		args = append(args, "--force")
	}
	args = append(args, id)
	return r.runCapture(ctx, args...)
}

// State fetches the container's runtime state JSON.
func (r *runcRunner) State(ctx context.Context, id string) (*State, error) {
	if id == "" {
		return nil, errors.New("runtime: container id is required")
	}
	stdout, stderr, err := r.runOutput(ctx, "state", id)
	if err != nil {
		return nil, fmt.Errorf("runtime: state %q: %w (%s)", id, err, strings.TrimSpace(string(stderr)))
	}
	var s State
	if err := json.Unmarshal(stdout, &s); err != nil {
		return nil, fmt.Errorf("runtime: parse state: %w (stdout=%q)", err, string(stdout))
	}
	return &s, nil
}

// runCapture runs the runc binary with args and captures stderr on error.
func (r *runcRunner) runCapture(ctx context.Context, args ...string) error {
	_, stderr, err := r.runOutput(ctx, args...)
	if err != nil {
		return fmt.Errorf("runtime: %s: %w (%s)", r.describe(args), err, strings.TrimSpace(string(stderr)))
	}
	return nil
}

// runOutput runs the runc binary with args and returns stdout + stderr.
func (r *runcRunner) runOutput(ctx context.Context, args ...string) ([]byte, []byte, error) {
	cmd := exec.CommandContext(ctx, r.bin, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.Bytes(), stderr.Bytes(), err
}

// describe renders an args slice into a short "runc <subcommand> ..." tag.
func (r *runcRunner) describe(args []string) string {
	if len(args) == 0 {
		return r.bin
	}
	return r.bin + " " + strings.Join(args[:min(2, len(args))], " ")
}

// sigName maps a syscall.Signal to its symbolic name (SIGTERM, SIGKILL, …)
// for `runc kill`. runc accepts the uppercased name without the "SIG" prefix
// too, but the full name is unambiguous and matches `kill -l` output.
func (r *runcRunner) sigName(s syscall.Signal) string {
	return signalName(s)
}

// ExecProcess invokes `runc exec --process <tmpfile> <id>` to run an
// additional process inside an already-running container. The OCI
// specs.Process is marshaled to a temp file inside bundleDir (so it lives
// next to the bundle's other artifacts); the file is removed before return.
//
// It is a package-level entry point, not a Runner interface method, so the
// Runner interface (used by the worker's Launcher abstraction) stays stable
// while the worker's Linux launcher still benefits from a single binary-
// resolution source.
//
// Exit-code semantics mirror Runner.Run: a non-zero process exit is
// returned with a nil error; only infrastructure failures (start failure,
// non-*exec.ExitError wait errors) return err.
func ExecProcess(ctx context.Context, id, bundleDir string, p *specs.Process, io StdIO) (int, error) {
	if id == "" {
		return 0, errors.New("runtime: container id is required")
	}
	if p == nil {
		return 0, errors.New("runtime: process spec is required")
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return 0, fmt.Errorf("runtime: marshal exec process: %w", err)
	}
	tmp, err := os.CreateTemp(bundleDir, "exec-process-*.json")
	if err != nil {
		return 0, fmt.Errorf("runtime: create exec process file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return 0, fmt.Errorf("runtime: write exec process file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return 0, fmt.Errorf("runtime: close exec process file: %w", err)
	}

	cmd := exec.CommandContext(ctx, runcBinary(), "exec", "--process", tmp.Name(), id)
	if io.In != nil {
		cmd.Stdin = io.In
	}
	if io.Out != nil {
		cmd.Stdout = io.Out
	}
	if io.Err != nil {
		cmd.Stderr = io.Err
	}
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("runtime: start %q exec: %w", runcBinary(), err)
	}
	werr := cmd.Wait()
	if werr == nil {
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(werr, &exitErr) {
		return exitErr.ExitCode(), nil
	}
	return 0, fmt.Errorf("runtime: wait %q exec: %w", runcBinary(), werr)
}
