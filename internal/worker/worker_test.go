package worker

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

// bufSize is the bufconn capacity; sized generously so a streaming RPC does
// not deadlock on backpressure in tests.
const bufSize = 1 << 20

// newServer starts a Worker (with the given Launcher + a trivial Resolve)
// on an in-memory bufconn and returns a connected *grpc.ClientConn plus a
// cleanup func.
func newServer(t *testing.T, launcher Launcher, resolve func(string) (ResolvedImage, error)) (voilapb.WorkerClient, func()) {
	t.Helper()
	_, cli, cleanup := newServerWithWorker(t, launcher, resolve)
	return cli, cleanup
}

// newServerWithWorker is like newServer but also hands back the *Worker
// backing the server. Tests that need direct access to the worker (e.g.
// to synchronise against subscribe before issuing a Run RPC) use it.
func newServerWithWorker(t *testing.T, launcher Launcher, resolve func(string) (ResolvedImage, error), cfgOpts ...func(*Config)) (*Worker, voilapb.WorkerClient, func()) {
	t.Helper()
	if resolve == nil {
		resolve = func(string) (ResolvedImage, error) {
			return ResolvedImage{Ref: "img:tag"}, nil
		}
	}
	cfg := Config{
		Root:     t.TempDir(),
		Resolve:  resolve,
		Launcher: launcher,
	}
	for _, opt := range cfgOpts {
		opt(&cfg)
	}
	w := NewWorker(cfg)
	lis := bufconn.Listen(bufSize)
	errCh := make(chan error, 1)
	go func() { errCh <- w.Serve(lis) }()

	dialer := func(ctx context.Context, _ string) (net.Conn, error) {
		return lis.DialContext(ctx)
	}
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(dialer),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}
	cleanup := func() {
		_ = conn.Close()
		_ = lis.Close()
		select {
		case <-errCh:
		case <-time.After(2 * time.Second):
		}
	}
	return w, voilapb.NewWorkerClient(conn), cleanup
}

// ===========================================================================
// fakeLauncher
// ===========================================================================

// fakeLauncher is a test Launcher whose Launch/Exec/Kill behaviour is
// scriptable. Each Launch registers a per-launch "killed" channel that Kill
// (called with the same ctxID) closes; this mirrors the real launcher's
// SIGKILL-terminates-runc relationship without needing runc.
type fakeLauncher struct {
	mu         sync.Mutex
	launches   []*fakeLaunch
	execs      []*fakeExec
	kills      []*fakeKill
	releases   map[string]chan struct{}
	launchBody fakeLaunchBody
	execBody   fakeExecBody
}

// fakeLaunchBody is the scriptable Launch body. killed is closed when Kill is
// called for spec.ID; body writers select on it (and ctx.Done) to terminate.
type fakeLaunchBody func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error)

type fakeExecBody func(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error)

type fakeLaunch struct {
	spec LaunchSpec
}

type fakeExec struct {
	ctxID string
	spec  ExecSpec
}

type fakeKill struct {
	ctxID string
	sig   syscall.Signal
}

func newFakeLauncher() *fakeLauncher {
	return &fakeLauncher{releases: map[string]chan struct{}{}}
}

// Launch: runs launchBody (or default). Registers a per-launch killed chan.
func (l *fakeLauncher) Launch(ctx context.Context, spec LaunchSpec, sink IOSink) (int, error) {
	killed := make(chan struct{})
	l.mu.Lock()
	l.launches = append(l.launches, &fakeLaunch{spec: spec})
	l.releases[spec.ID] = killed
	body := l.launchBody
	l.mu.Unlock()

	defer func() {
		l.mu.Lock()
		delete(l.releases, spec.ID)
		l.mu.Unlock()
	}()

	if body == nil {
		body = defaultLaunchBody
	}
	return body(ctx, spec, sink, killed)
}

// Exec runs execBody (or default echo).
func (l *fakeLauncher) Exec(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error) {
	l.mu.Lock()
	l.execs = append(l.execs, &fakeExec{ctxID: ctxID, spec: spec})
	body := l.execBody
	l.mu.Unlock()
	if body == nil {
		body = defaultExecBody
	}
	return body(ctx, ctxID, spec, sink)
}

// Kill records the signal and closes the per-launch "killed" channel for ctxID.
func (l *fakeLauncher) Kill(ctx context.Context, ctxID string, sig syscall.Signal) error {
	l.mu.Lock()
	l.kills = append(l.kills, &fakeKill{ctxID: ctxID, sig: sig})
	rel, ok := l.releases[ctxID]
	if ok {
		delete(l.releases, ctxID)
	}
	l.mu.Unlock()
	if ok {
		close(rel)
	}
	return nil
}

// defaultLaunchBody writes "hello\n", fires sink.Started with pid 1234, then
// blocks until killed or ctx-cancelled, mirroring a foreground runc run.
func defaultLaunchBody(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
	sink.Stdout([]byte("hello\n"))
	sink.Started(1234)
	go io.Copy(io.Discard, spec.Stdin) // drain so the stdin pipe doesn't block the pump
	select {
	case <-ctx.Done():
	case <-killed:
	}
	return 0, nil
}

// defaultExecBody echoes spec.Args to stdout and exits 0.
func defaultExecBody(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error) {
	sink.Stdout([]byte(strings.Join(spec.Args, " ") + "\n"))
	return 0, nil
}

// ===========================================================================
// Test helpers
// ===========================================================================

// startRun sends the spec on a fresh Run stream and returns it. The stream's
// send side is left open so a test that needs stdin can continue sending;
// tests that don't should CloseSend the stream after they have what they
// need.
func startRun(t *testing.T, c voilapb.WorkerClient, spec *voilapb.RunSpec) voilapb.Worker_RunClient {
	t.Helper()
	stream, err := c.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if err := stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_Spec{Spec: spec}}); err != nil {
		t.Fatalf("Send spec: %v", err)
	}
	return stream
}

// drainRun reads Run output frames through the exit_code frame, collecting
// stdout/stderr bytes along the way.
func drainRun(t *testing.T, stream voilapb.Worker_RunClient) (ctxID string, stdout, stderr []byte, exitCode int32, err error) {
	t.Helper()
	for {
		msg, rerr := stream.Recv()
		if rerr == io.EOF {
			err = rerr
			return
		}
		if rerr != nil {
			err = rerr
			return
		}
		switch o := msg.Output.(type) {
		case *voilapb.RunOutput_ContextId:
			ctxID = o.ContextId
		case *voilapb.RunOutput_Stdout:
			stdout = append(stdout, o.Stdout...)
		case *voilapb.RunOutput_Stderr:
			stderr = append(stderr, o.Stderr...)
		case *voilapb.RunOutput_ExitCode:
			exitCode = o.ExitCode
			return
		}
	}
}

// killAndAwaitFinish calls Kill on id, then drains the run stream to wait
// for the FINISHED transition (via Run's exit_code frame). The launch body
// returns when the fake launcher's killed chan closes, finishing the ctx.
func killAndAwaitFinish(t *testing.T, c voilapb.WorkerClient, id string, runStream voilapb.Worker_RunClient) {
	t.Helper()
	if _, err := c.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	awaitFinish(t, runStream)
}

// awaitFinish drains the run stream until the exit_code frame arrives or the
// stream closes, then returns. Useful when the test has already issued Kill
// separately (e.g. to assert Kill's RPC response) before waiting for finish.
func awaitFinish(t *testing.T, runStream voilapb.Worker_RunClient) {
	t.Helper()
	for {
		msg, err := runStream.Recv()
		if err != nil {
			return
		}
		if _, ok := msg.Output.(*voilapb.RunOutput_ExitCode); ok {
			return
		}
	}
}

// awaitContextRunning polls the Worker.List RPC until the named context's
// status reaches "running", or fails the test after a short deadline. The Run
// RPC sends its ContextId frame synchronously BEFORE the launcher goroutine
// is scheduled, so receiving the ContextId is NOT proof of Running — the
// launcher still has to call sink.Started(pid) and the FSM hub has to process
// that transition. Tests that issue Exec immediately after recv-ing the
// ContextId race the FSM: under load the Exec RPC frequently arrives while
// the FSM still has status=scheduled and returns FailedPrecondition. Test
// code that opens Exec or otherwise depends on Running should await via this
// helper first. (Exec itself does not wait — the worker's Exec handler is
// non-blocking by design, returning FailedPrecondition immediately when the
// context is not Running.)
func awaitContextRunning(t *testing.T, c voilapb.WorkerClient, id string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		resp, err := c.List(context.Background(), &voilapb.ListRequest{})
		if err != nil {
			t.Fatalf("List while awaiting running: %v", err)
		}
		for _, ci := range resp.GetContexts() {
			if ci.GetId() == id && ci.GetStatus() == "running" {
				return
			}
		}
		time.Sleep(2 * time.Millisecond)
	}
	// Snapshot the current List output for the failure message so the cause
	// (stuck in scheduled / never registered / etc.) is visible.
	snap, _ := c.List(context.Background(), &voilapb.ListRequest{})
	t.Fatalf("context %q never reached running within 3s (last List: %v)", id, snap)
}

// ===========================================================================
// Run happy path
// ===========================================================================

// TestRun_HappyPath asserts frames arrive in order: context_id, stdout,
// exit_code. The fake launcher writes "hello\n" and exits 0 immediately.
func TestRun_HappyPath(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Stdout([]byte("hello\n"))
		sink.Started(4242)
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img:tag"})
	_ = stream.CloseSend()

	ctxID, stdout, stderr, code, err := drainRun(t, stream)
	if err != nil && err != io.EOF {
		t.Fatalf("Recv: %v", err)
	}
	if ctxID == "" || !strings.HasPrefix(ctxID, "voila-") {
		t.Fatalf("ctxID = %q", ctxID)
	}
	if string(stdout) != "hello\n" {
		t.Errorf("stdout = %q", string(stdout))
	}
	if string(stderr) != "" {
		t.Errorf("stderr = %q", string(stderr))
	}
	if code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}

	if len(launcher.launches) != 1 {
		t.Fatalf("launches = %d", len(launcher.launches))
	}
	if got := launcher.launches[0].spec.ID; got != ctxID {
		t.Errorf("launch id = %q, ctxID = %q", got, ctxID)
	}
}

// TestRun_InvalidArgumentFirstMsg verifies a non-spec first message is
// rejected with InvalidArgument.
// TestRun_HappyPath_NoCloseSend verifies that a client which keeps the
// send side open (e.g. an interactive terminal whose stdin pump has not
// yet sent stdin_eof) still receives the exit_code frame and the Run
// handler returns. Before the fix, this deadlocked: Run waited for the
// stdin pump, but the stdin pump was blocked on stream.Recv() waiting for
// the client to CloseSend after exit_code.
func TestRun_HappyPath_NoCloseSend(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Stdout([]byte("hello\n"))
		sink.Started(4242)
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img:tag"})
	// Intentionally do NOT CloseSend here.

	done := make(chan struct{})
	var ctxID string
	var code int32
	var recvErr error
	go func() {
		defer close(done)
		ctxID, _, _, code, recvErr = drainRun(t, stream)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for exit_code frame; likely stdin/exit deadlock")
	}
	if recvErr != nil && recvErr != io.EOF {
		t.Fatalf("Recv: %v", recvErr)
	}
	if ctxID == "" || !strings.HasPrefix(ctxID, "voila-") {
		t.Fatalf("ctxID = %q", ctxID)
	}
	if code != 0 {
		t.Errorf("exit = %d, want 0", code)
	}
}

func TestRun_InvalidArgumentFirstMsg(t *testing.T) {
	cli, cleanup := newServer(t, newFakeLauncher(), nil)
	defer cleanup()

	stream, err := cli.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_Stdin{Stdin: []byte("oops")}}); err != nil {
		t.Fatalf("Send: %v", err)
	}
	_, err = stream.Recv()
	if err == nil {
		t.Fatal("expected error from invalid first message")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.InvalidArgument {
		t.Fatalf("code = %v, want InvalidArgument: %v", st.Code(), err)
	}
}

// TestRun_ResolveFailure verifies a failed Resolve returns InvalidArgument.
func TestRun_ResolveFailure(t *testing.T) {
	resolve := func(string) (ResolvedImage, error) {
		return ResolvedImage{}, errors.New("no such image")
	}
	cli, cleanup := newServer(t, newFakeLauncher(), resolve)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "missing"})
	_ = stream.CloseSend()
	_, err := stream.Recv()
	if err == nil {
		t.Fatal("expected error")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.InvalidArgument {
		t.Fatalf("code = %v, want InvalidArgument: %v", st.Code(), err)
	}
}

// ===========================================================================
// Stdin round trip
// ===========================================================================

// TestRun_StdinRoundTrip verifies stdin frames reach the launcher and EOF is
// forwarded via stdin_eof. The launcher echoes stdin → stdout.
func TestRun_StdinRoundTrip(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1234)
		buf := make([]byte, 0, 256)
		tmp := make([]byte, 256)
		for {
			n, rerr := spec.Stdin.Read(tmp)
			if n > 0 {
				buf = append(buf, tmp[:n]...)
				for {
					i := strings.IndexByte(string(buf), '\n')
					if i < 0 {
						break
					}
					sink.Stdout(append([]byte("echo: "), buf[:i+1]...))
					buf = buf[i+1:]
				}
			}
			if rerr != nil {
				break
			}
		}
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream, err := cli.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_Spec{Spec: &voilapb.RunSpec{Image: "img", AttachStdin: true}}}); err != nil {
		t.Fatalf("Send spec: %v", err)
	}
	if err := stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_Stdin{Stdin: []byte("one\n")}}); err != nil {
		t.Fatalf("Send stdin: %v", err)
	}
	if err := stream.Send(&voilapb.RunInput{Input: &voilapb.RunInput_StdinEof{}}); err != nil {
		t.Fatalf("Send eof: %v", err)
	}
	_ = stream.CloseSend()

	_, stdout, _, code, _ := drainRun(t, stream)
	if got := string(stdout); !strings.Contains(got, "echo: one\n") {
		t.Errorf("stdout = %q", got)
	}
	if code != 0 {
		t.Errorf("code = %d, want 0", code)
	}
}

// ===========================================================================
// Client disconnect mid-run
// ===========================================================================

// TestRun_DetachMidRun verifies that a client disconnect mid-run does NOT
// stop the context: a second client can Logs-follow it and observe remaining
// output, and a third client can Kill it and the FINISHED transition occurs.
func TestRun_DetachMidRun(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Stdout([]byte("first\n"))
		sink.Started(2222)
		go io.Copy(io.Discard, spec.Stdin)
		time.Sleep(50 * time.Millisecond)
		sink.Stdout([]byte("second\n"))
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	// 1. Client connects, reads ctxID + first stdout, then disconnects.
	c1Ctx, c1Cancel := context.WithCancel(context.Background())
	defer c1Cancel()
	c1, err := cli.Run(c1Ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := c1.Send(&voilapb.RunInput{Input: &voilapb.RunInput_Spec{Spec: &voilapb.RunSpec{Image: "img"}}}); err != nil {
		t.Fatal(err)
	}
	idMsg, err := c1.Recv()
	if err != nil {
		t.Fatalf("Recv ctxID: %v", err)
	}
	id := idMsg.GetContextId()
	first, err := c1.Recv()
	if err != nil {
		t.Fatalf("Recv first stdout: %v", err)
	}
	if string(first.GetStdout()) != "first\n" {
		t.Fatalf("first stdout = %q", string(first.GetStdout()))
	}
	// Disconnect client 1 mid-run by cancelling its context.
	_ = c1.CloseSend()
	c1Cancel()

	// Wait for "second" to be written to the ring after the disconnect.
	time.Sleep(200 * time.Millisecond)

	// 2. Client 2 attaches via Logs-follow.
	logsCtx, logsCancel := context.WithCancel(context.Background())
	defer logsCancel()
	logStream, err := cli.Logs(logsCtx, &voilapb.LogsRequest{ContextId: id, Follow: true})
	if err != nil {
		t.Fatal(err)
	}
	var seen []string
	deadline := time.After(3 * time.Second)
read:
	for {
		select {
		case <-deadline:
			t.Fatalf("Logs-follow timed out; seen=%v", seen)
		default:
		}
		chunk, rerr := logStream.Recv()
		if rerr == io.EOF {
			break read
		}
		if rerr != nil {
			// The stream may report transport error here only on client ctx
			// cancel below; otherwise it's a problem.
			if logStream.Context().Err() != nil {
				break read
			}
			t.Fatalf("Logs Recv: %v; seen=%v", rerr, seen)
		}
		seen = append(seen, string(chunk.GetData()))
		if strings.Join(seen, "") == "first\nsecond\n" {
			break read
		}
	}

	// 3. Kill via yet another client; verify FINISHED + exit 0.
	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	// Drain the Logs follower until EOF (ring finish closes the channel).
	for {
		_, rerr := logStream.Recv()
		if rerr != nil {
			break
		}
	}

	// 4. List shows Finished with exit code 0.
	listCtx, listCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer listCancel()
	resp, err := cli.List(listCtx, &voilapb.ListRequest{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	var found *voilapb.ContextInfo
	for _, c := range resp.GetContexts() {
		if c.GetId() == id {
			found = c
		}
	}
	if found == nil {
		t.Fatalf("context %s not in list", id)
	}
	if found.GetStatus() != "finished" {
		t.Errorf("status = %q, want finished", found.GetStatus())
	}
	if found.GetExitCode() != 0 {
		t.Errorf("exit = %d, want 0", found.GetExitCode())
	}
}

// ===========================================================================
// Exec against running / finished / unknown
// ===========================================================================

// TestExec_RunningAndFinished verifies Exec succeeds against a Running ctx
// but returns FailedPrecondition against a Finished one (and NotFound for
// unknown).
func TestExec_RunningAndFinished(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(4321)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-ctx.Done():
		case <-killed:
		}
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	id := idMsg.GetContextId()

	// The Run RPC sends the ContextId frame synchronously BEFORE the
	// launcher goroutine is scheduled, so recv-ing it is not proof the FSM
	// has transitioned to Running. Without this wait, Exec races the
	// FSM's scheduled→running transition and returns FailedPrecondition
	// intermittently (hit regularly under CI load; ~0% on a fast host).
	awaitContextRunning(t, cli, id)

	// Exec against the Running context: expect the default exec echo.
	execCtx, execCancel := context.WithCancel(context.Background())
	defer execCancel()
	execStream, err := cli.Exec(execCtx)
	if err != nil {
		t.Fatal(err)
	}
	if err := execStream.Send(&voilapb.ExecInput{Input: &voilapb.ExecInput_Spec{Spec: &voilapb.ExecSpec{ContextId: id, Args: []string{"/bin/ls"}}}}); err != nil {
		t.Fatalf("Send exec spec: %v", err)
	}
	_ = execStream.CloseSend()
	out, err := execStream.Recv()
	if err != nil {
		t.Fatalf("Recv exec: %v", err)
	}
	if string(out.GetStdout()) != "/bin/ls\n" {
		t.Errorf("exec stdout = %q", string(out.GetStdout()))
	}
	exit, err := execStream.Recv()
	if err != nil {
		t.Fatalf("Recv exec end: %v", err)
	}
	if exit.GetExitCode() != 0 {
		t.Errorf("exec exit = %d, want 0", exit.GetExitCode())
	}

	// Kill the context so it finishes, then Exec must FailedPrecondition.
	killAndAwaitFinish(t, cli, id, stream)

	exec2Ctx, exec2Cancel := context.WithCancel(context.Background())
	defer exec2Cancel()
	exec2, err := cli.Exec(exec2Ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := exec2.Send(&voilapb.ExecInput{Input: &voilapb.ExecInput_Spec{Spec: &voilapb.ExecSpec{ContextId: id, Args: []string{"x"}}}}); err != nil {
		t.Fatal(err)
	}
	_ = exec2.CloseSend()
	_, err = exec2.Recv()
	st, _ := status.FromError(err)
	if st.Code() != codes.FailedPrecondition {
		t.Fatalf("exec against finished: code=%v want FailedPrecondition: %v", st.Code(), err)
	}
}

// TestExec_UnknownContext verifies Exec against unknown ctx NotFound.
func TestExec_UnknownContext(t *testing.T) {
	cli, cleanup := newServer(t, newFakeLauncher(), nil)
	defer cleanup()

	stream, err := cli.Exec(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := stream.Send(&voilapb.ExecInput{Input: &voilapb.ExecInput_Spec{Spec: &voilapb.ExecSpec{ContextId: "nope", Args: []string{"x"}}}}); err != nil {
		t.Fatal(err)
	}
	_ = stream.CloseSend()
	_, err = stream.Recv()
	st, _ := status.FromError(err)
	if st.Code() != codes.NotFound {
		t.Fatalf("code=%v want NotFound: %v", st.Code(), err)
	}
}

// TestExec_OutputNotInTheRing verifies that Exec output does NOT appear in a
// subsequent Logs replay (documented: exec output stays off-ring).
func TestExec_OutputNotInTheRing(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Stdout([]byte("run-line\n"))
		sink.Started(1)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 0, nil
	}
	launcher.execBody = func(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error) {
		sink.Stdout([]byte("exec-line\n"))
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()
	// Drain the run-line stdout frame so it's in the ring before the exec.
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}

	// Run an exec that writes its own stdout (NOT into the ring).
	execCtx, execCancel := context.WithCancel(context.Background())
	defer execCancel()
	execS, err := cli.Exec(execCtx)
	if err != nil {
		t.Fatal(err)
	}
	if err := execS.Send(&voilapb.ExecInput{Input: &voilapb.ExecInput_Spec{Spec: &voilapb.ExecSpec{ContextId: id, Args: []string{"x"}}}}); err != nil {
		t.Fatal(err)
	}
	_ = execS.CloseSend()
	if _, err := execS.Recv(); err != nil {
		t.Fatal(err)
	}

	// Kill to finish the context (closes the ring), then replay-only Logs.
	killAndAwaitFinish(t, cli, id, stream)

	logsCtx, logsCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer logsCancel()
	logs, err := cli.Logs(logsCtx, &voilapb.LogsRequest{ContextId: id})
	if err != nil {
		t.Fatal(err)
	}
	var got []byte
	for {
		c, rerr := logs.Recv()
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			t.Fatal(rerr)
		}
		got = append(got, c.GetData()...)
	}
	if !strings.Contains(string(got), "run-line") {
		t.Errorf("ring missing run-line: %q", string(got))
	}
	if strings.Contains(string(got), "exec-line") {
		t.Errorf("ring contains exec-line (must not): %q", string(got))
	}
}

// ===========================================================================
// Logs replay vs follow vs unknown
// ===========================================================================

// TestLogs_ReplayOnly verifies a non-follow Logs returns the buffered chunks
// and closes the stream.
func TestLogs_ReplayOnly(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Stdout([]byte("one\ntwo\n"))
		sink.Started(1)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 0, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()
	// Wait for the stdout frame to land in the ring.
	if _, err := stream.Recv(); err != nil && err != io.EOF {
		t.Fatal(err)
	}

	logsCtx, logsCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer logsCancel()
	logs, err := cli.Logs(logsCtx, &voilapb.LogsRequest{ContextId: id})
	if err != nil {
		t.Fatal(err)
	}
	var got []byte
	for {
		c, rerr := logs.Recv()
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			t.Fatal(rerr)
		}
		got = append(got, c.GetData()...)
	}
	if !strings.Contains(string(got), "one") || !strings.Contains(string(got), "two") {
		t.Errorf("replay = %q", string(got))
	}

	// Kill to allow cleanup (release the launch goroutine).
	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatal(err)
	}
}

// TestLogs_UnknownContext verifies Logs against unknown ctx NotFound.
func TestLogs_UnknownContext(t *testing.T) {
	cli, cleanup := newServer(t, newFakeLauncher(), nil)
	defer cleanup()
	stream, err := cli.Logs(context.Background(), &voilapb.LogsRequest{ContextId: "nope"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = stream.Recv()
	st, _ := status.FromError(err)
	if st.Code() != codes.NotFound {
		t.Fatalf("code = %v want NotFound: %v", st.Code(), err)
	}
}

// ===========================================================================
// Kill semantics
// ===========================================================================

// TestKill_NotRunning verifies Kill against a non-running ctx (Finished here:
// the launch returned 0 immediately, prompting finish) returns
// FailedPrecondition.
func TestKill_NotRunning(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1)
		return 0, nil // exits immediately → finish → Finished
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()
	// Wait for the exit_code frame so the ctx is Finished.
	for {
		msg, err := stream.Recv()
		if err != nil {
			break
		}
		if _, ok := msg.Output.(*voilapb.RunOutput_ExitCode); ok {
			break
		}
	}

	_, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id})
	if err == nil {
		t.Fatal("expected FailedPrecondition")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.FailedPrecondition {
		t.Fatalf("code = %v, want FailedPrecondition: %v", st.Code(), err)
	}
}

// TestKill_RunningSendsSIGTERM verifies Kill on a Running ctx forwards
// SIGTERM (signal 0) to the launcher and the launcher's killed chan fires.
func TestKill_RunningSendsSIGTERM(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 0, nil
	}
	// Short grace: this fake exits on SIGTERM, so escalation never fires,
	// but Kill still waits out the window before checking status.
	_, cli, cleanup := newServerWithWorker(t, launcher, nil, func(c *Config) { c.KillGrace = 10 * time.Millisecond })
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()

	awaitContextRunning(t, cli, id)
	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatalf("Kill: %v", err)
	}
	awaitFinish(t, stream)

	if len(launcher.kills) != 1 || launcher.kills[0].sig != syscall.SIGTERM {
		t.Fatalf("kills = %+v, want [SIGTERM]", launcher.kills)
	}
}

// TestKill_TermEscalatesToSIGKILL verifies that a container which ignores
// SIGTERM (as an init process without a handler does: the kernel discards
// fatal-default signals delivered to a PID-namespace child reaper) still
// terminates via the default kill: after the grace window the worker
// escalates to SIGKILL.
func TestKill_TermEscalatesToSIGKILL(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1)
		go io.Copy(io.Discard, spec.Stdin)
		// Ignores `killed` entirely — mirrors python -c 'time.sleep(...)',
		// which has no SIGTERM handler and is PID 1 of its PID namespace.
		time.Sleep(10 * time.Second)
		return 0, nil
	}
	const grace = 100 * time.Millisecond
	_, cli, cleanup := newServerWithWorker(t, launcher, nil, func(c *Config) { c.KillGrace = grace })
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()
	awaitContextRunning(t, cli, id)

	start := time.Now()
	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatalf("Kill: %v", err)
	}

	launcher.mu.Lock()
	defer launcher.mu.Unlock()
	if len(launcher.kills) != 2 {
		t.Fatalf("kills = %+v, want [SIGTERM SIGKILL]", launcher.kills)
	}
	if launcher.kills[0].sig != syscall.SIGTERM || launcher.kills[1].sig != syscall.SIGKILL {
		t.Fatalf("sigs = [%v %v], want [SIGTERM SIGKILL]", launcher.kills[0].sig, launcher.kills[1].sig)
	}
	if elapsed := time.Since(start); elapsed < grace {
		t.Fatalf("Kill returned after %v, want >= grace %v", elapsed, grace)
	}
}

// ===========================================================================
// List statuses
// ===========================================================================

// TestList_Statuses verifies List snapshots all registered contexts with
// their current status (scheduled|running|finished), pid, and exit code.
func TestList_Statuses(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1234)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 7, nil
	}
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = stream.CloseSend()
	idMsg, _ := stream.Recv()
	id := idMsg.GetContextId()

	awaitContextRunning(t, cli, id)
	resp, err := cli.List(context.Background(), &voilapb.ListRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.GetContexts()) != 1 {
		t.Fatalf("contexts = %v", resp)
	}
	c0 := resp.GetContexts()[0]
	if c0.GetStatus() != "running" || c0.GetPid() != 1234 {
		t.Fatalf("ctx while running: %+v", c0)
	}

	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatal(err)
	}
	awaitFinish(t, stream)

	resp2, err := cli.List(context.Background(), &voilapb.ListRequest{})
	if err != nil {
		t.Fatal(err)
	}
	c0 = resp2.GetContexts()[0]
	if c0.GetStatus() != "finished" || c0.GetExitCode() != 7 || c0.GetPid() != 0 {
		t.Fatalf("ctx after finish: %+v", c0)
	}
}

// ===========================================================================
// Events end-to-end
// ===========================================================================

// TestEvents_Stream verifies the Events RPC delivers the lifecycle sequence
// (SCHEDULED → STARTED → FINISHED with exit code) for one context.
func TestEvents_Stream(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(5)
		go io.Copy(io.Discard, spec.Stdin)
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 3, nil
	}
	w, cli, cleanup := newServerWithWorker(t, launcher, nil)
	defer cleanup()

	// Subscribe BEFORE launching so we capture SCHEDULED.
	evtCtx, evtCancel := context.WithCancel(context.Background())
	defer evtCancel()
	stream, err := cli.Events(evtCtx, &voilapb.EventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	// Wait until the server-side Events handler has actually registered its
	// subscriber with the hub. The Events RPC starts asynchronously on its
	// own goroutine; without this gate, Run invoked next could publish
	// SCHEDULED before subscribe() returns, and the hub drops the event
	// (no subscribers at publish time).
	subDeadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(subDeadline) {
		if w.hub.subscriberCount() >= 1 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if w.hub.subscriberCount() < 1 {
		t.Fatal("events subscriber never registered")
	}
	ev := make(chan *voilapb.Event, 16)
	go func() {
		for {
			e, rerr := stream.Recv()
			if rerr != nil {
				close(ev)
				return
			}
			ev <- e
		}
	}()

	runStream := startRun(t, cli, &voilapb.RunSpec{Image: "img"})
	_ = runStream.CloseSend()
	idMsg, _ := runStream.Recv()
	id := idMsg.GetContextId()
	// The Run RPC sends the ContextId frame before the launcher goroutine
	// calls sink.Started, so Kill issued immediately after recv can race
	// the FSM and hit FailedPrecondition (status=scheduled) under load.
	// Wait for Running first — same gate the Exec tests use.
	awaitContextRunning(t, cli, id)
	killAndAwaitFinish(t, cli, id, runStream)

	// Collect SCHEDULED, STARTED, FINISHED(exit=3) in order.
	wantSeq := []struct {
		typ  voilapb.EventType
		exit int32
	}{
		{voilapb.EventType_EVENT_TYPE_SCHEDULED, 0},
		{voilapb.EventType_EVENT_TYPE_STARTED, 0},
		{voilapb.EventType_EVENT_TYPE_FINISHED, 3},
	}
	deadline := time.After(2 * time.Second)
	for i := 0; i < len(wantSeq); i++ {
		select {
		case e, ok := <-ev:
			if !ok {
				t.Fatalf("event stream closed at %d", i)
			}
			if e.GetType() != wantSeq[i].typ {
				t.Errorf("event %d: type=%v want %v", i, e.GetType(), wantSeq[i].typ)
			}
			if e.GetExitCode() != wantSeq[i].exit {
				t.Errorf("event %d: exit=%d want %d", i, e.GetExitCode(), wantSeq[i].exit)
			}
		case <-deadline:
			t.Fatalf("no event %d", i)
		}
	}
}

// ===========================================================================
// Fetch stats wiring (RunOutput_Stats frame + List live snapshot)
// ===========================================================================

// testStore is a minimal chunk store for the worker stats tests: Get serves
// a fixed payload for two known ids (so the fake launcher can simulate
// reads via spec.Store). Stat/GC/Close are stubs; we only need Get through
// the CountingStore wrapper.
type testStore struct{}

const (
	chunkABytes = 11
	chunkBBytes = 7
)

var (
	testChunkA = chunkstore.ChunkID{0xa1, 0xa1}
	testChunkB = chunkstore.ChunkID{0xb2, 0xb2}
)

func (testStore) Put(buf []byte) (chunkstore.ChunkID, error) {
	return chunkstore.ChunkID{}, errors.New("not used")
}
func (testStore) Get(ctx context.Context, id chunkstore.ChunkID) ([]byte, error) {
	switch id {
	case testChunkA:
		return make([]byte, chunkABytes), nil
	case testChunkB:
		return make([]byte, chunkBBytes), nil
	}
	return nil, chunkstore.ErrNotFound
}
func (testStore) Stat(id chunkstore.ChunkID) (chunkstore.ChunkMeta, bool) {
	return chunkstore.ChunkMeta{}, true
}
func (testStore) GC(reachable map[chunkstore.ChunkID]struct{}) (int, error) { return 0, nil }
func (testStore) Close() error                                              { return nil }

// TestRun_StatsFrameBeforeExitCode wires a real ChunkStore into the Worker,
// drives the fake launcher to read two distinct chunks via spec.Store (the
// CountingStore wrapper the worker installs), and asserts: the Run stream
// yields a Stats frame populated from the counting store + the resolved
// image totals, BEFORE the exit_code frame; and that List exposes the live
// stats snapshot while the context is still Running and after it finishes.
func TestRun_StatsFrameBeforeExitCode(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(99)
		// Simulate the container touching two distinct chunks via the
		// per-context store the worker threaded in. The wrapper records
		// them once each (repeat Gets below verify distinct-count).
		if spec.Store == nil {
			t.Fatal("spec.Store is nil; the worker should wrap cfg.Store")
		}
		_, _ = spec.Store.Get(ctx, testChunkA)
		_, _ = spec.Store.Get(ctx, testChunkA) // repeat: counts once
		_, _ = spec.Store.Get(ctx, testChunkB)
		// Stay running so the middle-of-run List below sees a live counter.
		select {
		case <-killed:
		case <-ctx.Done():
		}
		return 0, nil
	}
	resolve := func(string) (ResolvedImage, error) {
		return ResolvedImage{
			Ref:         "img:tag",
			RootChunk:   chunkstore.ChunkID{0xaa},
			ConfigChunk: chunkstore.ChunkID{0xbb},
			ImageChunks: 26647,
			ImageBytes:  1050 * 1000 * 1000, // ~1.05 GiB for the pct rendering
		}, nil
	}
	w := NewWorker(Config{
		Root:     t.TempDir(),
		Store:    testStore{},
		Resolve:  resolve,
		Launcher: launcher,
	})
	lis := bufconn.Listen(bufSize)
	errCh := make(chan error, 1)
	go func() { errCh <- w.Serve(lis) }()
	dialer := func(ctx context.Context, _ string) (net.Conn, error) { return lis.DialContext(ctx) }
	conn, err := grpc.NewClient("passthrough:///bufnet",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(dialer),
	)
	if err != nil {
		t.Fatalf("grpc.NewClient: %v", err)
	}
	defer func() {
		_ = conn.Close()
		_ = lis.Close()
		select {
		case <-errCh:
		case <-time.After(2 * time.Second):
		}
	}()
	cli := voilapb.NewWorkerClient(conn)

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img:tag"})
	idMsg, err := stream.Recv()
	if err != nil {
		t.Fatalf("Recv ctxID: %v", err)
	}
	id := idMsg.GetContextId()
	// Close the send side so the worker's stdin pump exits (io.EOF on the
	// server Recv) once the launch body returns; otherwise the test
	// blocks on the pump goroutine indefinitely.
	_ = stream.CloseSend()

	// List while the context is still Running: the live counter has not
	// necessarily recorded reads yet (the launch goroutine races against
	// us), so we just assert the stats frame is non-nil (the counter
	// exists). The snapshot is taken under the context's statsMu so it
	// does not race the launch goroutine's Get.
	awaitContextRunning(t, cli, id)
	listResp, err := cli.List(context.Background(), &voilapb.ListRequest{})
	if err != nil {
		t.Fatalf("List live: %v", err)
	}
	var liveStats *voilapb.FetchStats
	for _, c := range listResp.GetContexts() {
		if c.GetId() == id {
			liveStats = c.GetStats()
		}
	}
	if liveStats == nil {
		t.Fatalf("live List did not expose stats for %s", id)
	}
	// Image totals must be plumbed through even before the run records any chunks.
	if liveStats.GetImageChunks() != 26647 || liveStats.GetImageBytes() != 1050*1000*1000 {
		t.Errorf("live stats image totals = {%d, %d}, want {26647, 1050000000}",
			liveStats.GetImageChunks(), liveStats.GetImageBytes())
	}

	// Kill to finish the launch goroutine, then drain the run stream,
	// collecting frames until exit_code; the Stats frame MUST appear
	// immediately before exit_code.
	if _, err := cli.Kill(context.Background(), &voilapb.KillRequest{ContextId: id}); err != nil {
		t.Fatalf("Kill: %v", err)
	}

	var (
		gotStats      *voilapb.FetchStats
		gotExit       int32
		sawStats      bool
		statsThenExit bool
	)
	for {
		msg, rerr := stream.Recv()
		if rerr == io.EOF {
			break
		}
		if rerr != nil && rerr != io.EOF {
			t.Fatalf("Recv: %v", rerr)
		}
		switch o := msg.Output.(type) {
		case *voilapb.RunOutput_Stats:
			if gotExit != 0 || sawStats {
				t.Errorf("Stats frame after exit or duplicate: prior exit=%d sawStats=%v", gotExit, sawStats)
			}
			gotStats = o.Stats
			sawStats = true
			statsThenExit = true
		case *voilapb.RunOutput_ExitCode:
			gotExit = o.ExitCode
			if !sawStats {
				t.Error("exit_code frame arrived without a preceding Stats frame")
			}
			// exit_code is terminal; one more Recv should be EOF.
			if _, err := stream.Recv(); err != io.EOF && err != nil {
				t.Errorf("expected EOF after exit_code, got %v", err)
			}
			goto done
		}
	}
done:
	if !sawStats || !statsThenExit {
		t.Fatal("Run stream did not yield a Stats frame before exit_code")
	}
	if gotStats == nil {
		t.Fatal("gotStats is nil")
	}
	if gotStats.GetChunksFetched() != 2 {
		t.Errorf("Stats.ChunksFetched = %d, want 2 (distinct chunks)", gotStats.GetChunksFetched())
	}
	wantBytes := uint64(chunkABytes + chunkBBytes)
	if gotStats.GetBytesFetched() != wantBytes {
		t.Errorf("Stats.BytesFetched = %d, want %d", gotStats.GetBytesFetched(), wantBytes)
	}
	if gotStats.GetImageChunks() != 26647 {
		t.Errorf("Stats.ImageChunks = %d, want 26647", gotStats.GetImageChunks())
	}
	if gotStats.GetImageBytes() != 1050*1000*1000 {
		t.Errorf("Stats.ImageBytes = %d, want 1050000000", gotStats.GetImageBytes())
	}

	// Final List: stats must now reflect the same counter snapshot (the
	// counting store stays referenced on the finished context for List).
	listResp2, err := cli.List(context.Background(), &voilapb.ListRequest{})
	if err != nil {
		t.Fatalf("List after finish: %v", err)
	}
	var finalStats *voilapb.FetchStats
	for _, c := range listResp2.GetContexts() {
		if c.GetId() == id {
			finalStats = c.GetStats()
		}
	}
	if finalStats == nil {
		t.Fatalf("final List did not expose stats for %s", id)
	}
	if finalStats.GetChunksFetched() != 2 || finalStats.GetBytesFetched() != wantBytes {
		t.Errorf("final stats = {%d, %d}, want {2, %d}", finalStats.GetChunksFetched(), finalStats.GetBytesFetched(), wantBytes)
	}
}

// TestRun_StatsOmittedForNilStore asserts that a Worker WITHOUT a cfg.Store
// (the tests / stub-launcher default) does NOT send a Stats frame: the
// counting wrapper is nil and the post-run path is nil-safe.
func TestRun_StatsOmittedForNilStore(t *testing.T) {
	launcher := newFakeLauncher()
	launcher.launchBody = func(ctx context.Context, spec LaunchSpec, sink IOSink, killed <-chan struct{}) (int, error) {
		sink.Started(1)
		if spec.Store != nil {
			t.Errorf("spec.Store = %v, want nil without cfg.Store", spec.Store)
		}
		return 0, nil
	}
	// newServer wires a nil cfg.Store; verify runDaemon's nil-counter path.
	cli, cleanup := newServer(t, launcher, nil)
	defer cleanup()

	stream := startRun(t, cli, &voilapb.RunSpec{Image: "img:tag"})
	_ = stream.CloseSend()
	var sawStats bool
	for {
		msg, err := stream.Recv()
		if err != nil {
			t.Fatalf("Recv: %v", err)
		}
		switch o := msg.Output.(type) {
		case *voilapb.RunOutput_Stats:
			sawStats = true
			_ = o
		case *voilapb.RunOutput_ExitCode:
			if sawStats {
				t.Error("Stats frame sent despite nil cfg.Store (should be suppressed)")
			}
			return
		}
	}
}
