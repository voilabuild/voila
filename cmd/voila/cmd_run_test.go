package main

import (
	"bytes"
	"errors"
	"os"
	"testing"

	"voila/internal/cli"
)

// TestExitCodeError_As verifies the errors.As plumbing that main.run relies
// on. cmdRun returns *exitCodeError directly (never wrapped), so errors.As
// must surface the .Code. This covers the propagation contract called out
// in the task spec without invoking the full run pipeline (which needs Linux +
// an ingested image).
func TestExitCodeError_As(t *testing.T) {
	err := &exitCodeError{Code: 42}
	var target *exitCodeError
	if !errors.As(err, &target) {
		t.Fatal("errors.As should match *exitCodeError")
	}
	if target.Code != 42 {
		t.Errorf("Code = %d, want 42", target.Code)
	}
	if err.Error() == "" {
		t.Error("Error() should not be empty")
	}
}

// runWithStderr runs run(args) with os.Stderr swapped to a buffer, returning
// the exit code and the captured stderr text. main.run hard-codes cfg.Stderr
// to os.Stderr, so the swap is the easiest capture path.
func runWithStderr(args []string) (int, string) {
	old := os.Stderr
	r, w, _ := os.Pipe()
	os.Stderr = w
	code := run(args)
	_ = w.Close()
	os.Stderr = old
	var buf bytes.Buffer
	_, _ = buf.ReadFrom(r)
	return code, buf.String()
}

// stubRoot swaps the command tree for one containing a single test command
// whose Run returns runErr. The returned func restores the original.
func stubRoot(t *testing.T, name string, runErr error) (restore func()) {
	t.Helper()
	orig := newRoot
	newRoot = func(cfg Config) *cli.Command {
		return &cli.Command{
			Name: "voila",
			Subs: []*cli.Command{
				{Name: name, Run: func([]string) error { return runErr }},
			},
		}
	}
	return func() { newRoot = orig }
}

// TestRun_ExitCodeErrorPropagation registers a throwaway subcommand that
// returns an *exitCodeError and verifies run() forwards its code WITHOUT
// printing the standard "voila <cmd>: <err>" line (so a failing program
// surfaces indistinguishably from running it directly).
func TestRun_ExitCodeErrorPropagation(t *testing.T) {
	const name = "__test_exitcodeonly__"
	restore := stubRoot(t, name, &exitCodeError{Code: 7})
	defer restore()

	code, stderr := runWithStderr([]string{name})
	if code != 7 {
		t.Fatalf("run exit code = %d, want 7", code)
	}
	if stderr != "" {
		t.Errorf("stderr non-empty (must be silent for exitCodeError): %q", stderr)
	}
}

// TestRun_PlainErrorPrintsAndReturnsOne confirms a non-exitCodeError still
// gets the "voila <cmd>: <err>" line and exit code 1.
func TestRun_PlainErrorPrintsAndReturnsOne(t *testing.T) {
	const name = "__test_plainerr__"
	restore := stubRoot(t, name, errors.New("boom"))
	defer restore()

	code, stderr := runWithStderr([]string{name})
	if code != 1 {
		t.Fatalf("run exit code = %d, want 1", code)
	}
	if stderr == "" {
		t.Error("stderr empty (must print plain error)")
	}
}
