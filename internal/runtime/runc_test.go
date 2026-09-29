package runtime

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

// writeFakeBin writes an executable shell script named `runc` into dir that
// dispatches on $1..$n. It honors the env in `script` body; returns the path.
func writeFakeBin(t *testing.T, script string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake-runner tests are POSIX-shell based")
	}
	dir := t.TempDir()
	// Prefer sh for portability across macOS/Linux.
	body := "#!/bin/sh\nset -e\n" + script
	path := filepath.Join(dir, "runc")
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// withBin sets VOILA_RUNTIME_BIN to the fake script and restores it on test
// completion. NewRunc reads the env at construction.
func withBin(t *testing.T, path string) {
	t.Helper()
	old := os.Getenv(runcBinEnv)
	os.Setenv(runcBinEnv, path)
	t.Cleanup(func() { os.Setenv(runcBinEnv, old) })
}

// TestRuncRun_ExitCode verifies a non-zero container exit surfaces as the
// returned code with nil error.
func TestRuncRun_ExitCode(t *testing.T) {
	// Script mimics `runc run --bundle <bundle> <id>`: it ignores the bundle
	// and id and exits 7.
	bin := writeFakeBin(t, `
case "$1" in
  run) exit 7 ;;
  *) echo fake: unknown cmd "$1" >&2; exit 64 ;;
esac
`)
	withBin(t, bin)

	runner := NewRunc()
	var out, errb bytes.Buffer
	code, err := runner.Run(context.Background(), "id1", "/bundle", StdIO{In: nil, Out: &out, Err: &errb})
	if err != nil {
		t.Fatalf("Run err = %v, want nil (container exit 7 is not infrastructure)", err)
	}
	if code != 7 {
		t.Fatalf("Run code = %d, want 7", code)
	}
}

// TestRuncRun_ExitZero verifies a zero container exit returns (0, nil).
func TestRuncRun_ExitZero(t *testing.T) {
	bin := writeFakeBin(t, `
case "$1" in
  run) exit 0 ;;
  *) exit 64 ;;
esac
`)
	withBin(t, bin)
	code, err := NewRunc().Run(context.Background(), "id", "/b", StdIO{})
	if err != nil {
		t.Fatalf("Run err = %v", err)
	}
	if code != 0 {
		t.Errorf("Run code = %d, want 0", code)
	}
}

// TestRuncRun_StdoutStderr verifies std streams are forwarded to the child.
func TestRuncRun_StdoutStderr(t *testing.T) {
	bin := writeFakeBin(t, `
case "$1" in
  run) echo hello-out; echo hello-err >&2; exit 0 ;;
  *) exit 64 ;;
esac
`)
	withBin(t, bin)
	var out, errb bytes.Buffer
	if _, err := NewRunc().Run(context.Background(), "id", "/b", StdIO{Out: &out, Err: &errb}); err != nil {
		t.Fatalf("Run err = %v", err)
	}
	if !strings.Contains(out.String(), "hello-out") {
		t.Errorf("stdout = %q, want contains hello-out", out.String())
	}
	if !strings.Contains(errb.String(), "hello-err") {
		t.Errorf("stderr = %q, want contains hello-err", errb.String())
	}
}

// TestRuncRun_Stdin verifies stdin is forwarded to the child.
func TestRuncRun_Stdin(t *testing.T) {
	bin := writeFakeBin(t, `
case "$1" in
  run) cat; exit 0 ;;
  *) exit 64 ;;
esac
`)
	withBin(t, bin)
	in := strings.NewReader("input-bytes\n")
	var out bytes.Buffer
	if _, err := NewRunc().Run(context.Background(), "id", "/b", StdIO{In: in, Out: &out}); err != nil {
		t.Fatalf("Run err = %v", err)
	}
	if !strings.Contains(out.String(), "input-bytes") {
		t.Errorf("stdout = %q, want echo of stdin", out.String())
	}
}

// TestRuncRun_BinaryMissing verifies the error path when the binary does not
// exist (infrastructure failure → err non-nil).
func TestRuncRun_BinaryMissing(t *testing.T) {
	withBin(t, "/nonexistent/path/that/does/not/exist/runc")
	_, err := NewRunc().Run(context.Background(), "id", "/b", StdIO{})
	if err == nil {
		t.Fatal("expected err for missing binary")
	}
	// The error wraps the start failure.
	if !strings.Contains(err.Error(), "start") && !strings.Contains(err.Error(), "no such file") {
		t.Errorf("err = %v, want to mention start/binary missing", err)
	}
}

// TestRuncRun_ArgValidation verifies the empty-id / empty-bundle rejection.
func TestRuncRun_ArgValidation(t *testing.T) {
	bin := writeFakeBin(t, `exit 0`)
	withBin(t, bin)
	r := NewRunc()
	if _, err := r.Run(context.Background(), "", "/b", StdIO{}); err == nil {
		t.Error("empty id should error")
	}
	if _, err := r.Run(context.Background(), "id", "", StdIO{}); err == nil {
		t.Error("empty bundle should error")
	}
}

// fakeStateScript emits JSON mimicking `runc state <id>`.
const fakeStateScript = `
case "$1" in
  state)
    case "$2" in
      good)   echo '{"ociVersion":"1.2.0","id":"good","status":"running","pid":12345,"bundle":"/b"}' ;;
      bad)   echo 'not-json{}' ;;
      *)     echo '{}' >&2; exit 1 ;;
    esac
    ;;
  kill)
    echo "kill $2 $3" >>"$0.log"
    exit 0
    ;;
  delete)
    if [ "$2" = "--force" ]; then
      echo "delete --force $3" >>"$0.log"
    else
      echo "delete $2" >>"$0.log"
    fi
    exit 0
    ;;
  run) exit 0 ;;
  *) echo fake: unknown "$1" >&2; exit 64 ;;
esac
`

// TestRuncState_ParsesJSON verifies State decodes runc state JSON.
func TestRuncState_ParsesJSON(t *testing.T) {
	bin := writeFakeBin(t, fakeStateScript)
	withBin(t, bin)
	st, err := NewRunc().State(context.Background(), "good")
	if err != nil {
		t.Fatalf("State err = %v", err)
	}
	if st.ID != "good" {
		t.Errorf("ID = %q, want good", st.ID)
	}
	if st.Status != "running" {
		t.Errorf("Status = %q, want running", st.Status)
	}
	if st.Pid != 12345 {
		t.Errorf("Pid = %d, want 12345", st.Pid)
	}
	if st.Bundle != "/b" {
		t.Errorf("Bundle = %q, want /b", st.Bundle)
	}
}

// TestRuncState_BadJSON verifies a malformed JSON reply wraps an error.
func TestRuncState_BadJSON(t *testing.T) {
	bin := writeFakeBin(t, fakeStateScript)
	withBin(t, bin)
	if _, err := NewRunc().State(context.Background(), "bad"); err == nil {
		t.Fatal("expected parse error")
	}
}

// TestRuncState_Missing verifies runc returning a non-zero with stderr is
// surfaced as a wrapped error.
func TestRuncState_Missing(t *testing.T) {
	bin := writeFakeBin(t, fakeStateScript)
	withBin(t, bin)
	_, err := NewRunc().State(context.Background(), "missing")
	if err == nil {
		t.Fatal("expected error for missing id")
	}
	// The error must wrap with command context.
	if !strings.Contains(err.Error(), "state") {
		t.Errorf("error %v should mention state", err)
	}
}

// TestRuncKill_PassesSignal verifies Kill invokes `runc kill <id> <sig>`
// with the symbolic signal name and returns nil.
func TestRuncKill_PassesSignal(t *testing.T) {
	bin := writeFakeBin(t, fakeStateScript)
	withBin(t, bin)
	if err := NewRunc().Kill(context.Background(), "ctx1", syscall.SIGTERM); err != nil {
		t.Fatalf("Kill err = %v", err)
	}
	logPath := bin + ".log"
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read kill log: %v", err)
	}
	if !strings.Contains(string(data), "kill ctx1 SIGTERM") {
		t.Errorf("kill log = %q, want ctx1 SIGTERM", string(data))
	}
}

// TestRuncDelete_PassesForce verifies Delete forwards the --force flag.
func TestRuncDelete_PassesForce(t *testing.T) {
	bin := writeFakeBin(t, fakeStateScript)
	withBin(t, bin)
	r := NewRunc()
	if err := r.Delete(context.Background(), "ctx1", true); err != nil {
		t.Fatalf("Delete(force=true) err = %v", err)
	}
	if err := r.Delete(context.Background(), "ctx2", false); err != nil {
		t.Fatalf("Delete(force=false) err = %v", err)
	}
	logPath := bin + ".log"
	data, _ := os.ReadFile(logPath)
	body := string(data)
	if !strings.Contains(body, "delete --force ctx1") {
		t.Errorf("delete log = %q, want --force ctx1", body)
	}
	if !strings.Contains(body, "delete ctx2") {
		t.Errorf("delete log = %q, want delete ctx2", body)
	}
}

// TestRunnerInterface_Conformance is a static check that runcRunner
// implements Runner.
func TestRunnerInterface_Conformance(t *testing.T) {
	var _ Runner = (*runcRunner)(nil)
	// exec.ExitError must not slip through Run as a real error in our
	// error checks; this just confirms the type is what we expect.
	var ee *exec.ExitError
	if !errors.As((*exec.ExitError)(nil), &ee) {
		t.Fatal("exec.ExitError type assertion failure")
	}
}
