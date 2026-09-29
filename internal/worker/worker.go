// Package worker implements the voila worker daemon: a gRPC service that
// owns run contexts (FSM lifecycle, ring-buffered logs, event broadcast) and
// drives aLauncher (mount+runc on Linux, error stub everywhere else) to
// actually launch/exec containers. The service contract is defined in
// internal/proto/worker.proto and generated into worker_grpc.pb.go.
//
// This file holds the OS-independent pieces: the Worker struct and registry,
// the injected Config/Launcher/IOSink contracts, and the gRPC service
// methods (Run/Exec/Events/Logs/List/Kill). Anything that touches the actual
// FUSE mount or runc lives in launch_linux.go (and a no-op stub elsewhere).
package worker

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// ResolvedImage is the post-resolution view of an image: the ref, the two
// chunk ids the launcher needs (merged-root manifest + OCI image config),
// and the image's ingest-time totals that feed the "X% of N chunks / M B"
// fetch-stats line after a run. ImageChunks / ImageBytes are 0 when the
// totals are unknown (e.g. the images.db row is missing for an older
// ingest); the stats line omits the parenthetical in that case.
type ResolvedImage struct {
	Ref         string
	RootChunk   chunkstore.ChunkID
	ConfigChunk chunkstore.ChunkID
	ImageChunks uint64 // total chunks recorded at ingest (0 = unknown)
	ImageBytes  uint64 // total bytes-in recorded at ingest (0 = unknown)
}

// Config holds the injected dependencies a Worker needs at construction.
// Tests substitute a fake Launcher (and a fake Resolve) so the service logic
// is exercised without touching mount.Mount or runtime.NewRunc; production
// uses the platform launcher defined in launch_linux.go / launch_stub.go.
type Config struct {
	// Root is the voila root directory (the parent of ctx/, images.db, ...).
	Root string
	// Store is the chunk store used to load image config / root chunks at
	// launch time. It is only touched by the platform launcher. Run wraps
	// it in a CountingStore before threading it to the launcher so the
	// per-context fetch stats account for every chunk read during a run.
	Store chunkstore.ChunkStore
	// Resolve maps a client-supplied image query to a resolved image:
	// ref + the merged-root manifest chunk + the OCI image config chunk +
	// the image's ingest-time totals (used to print the "X% of N chunks"
	// fraction after the run). Mirrors cmd/voila's resolveImage +
	// imageStore but is injected so the daemon can run without importing
	// cmd/. The returned ChunkIDs identify the merged-root manifest
	// chunk and the OCI image config chunk respectively.
	Resolve func(query string) (ResolvedImage, error)
	// TraceDir, when non-empty, enables per-run access tracing: Run wraps
	// the store in a chunkstore.TraceStore and writes a JSONL trace of every
	// chunk Get (hit/miss, wait time, demand/prefetch source) plus lifecycle
	// phase markers to <TraceDir>/<timestamp>-<ctxid>.jsonl. The directory
	// must exist. Empty disables tracing (zero overhead).
	TraceDir string
	// Launcher is the platform launcher (mount+runc on Linux, error stub
	// elsewhere). If nil, NewWorker substitutes the platform launcher.
	Launcher Launcher
	// RingBytes is the per-context ring buffer byte budget. Zero applies
	// the default (1 MiB; plan §8).
	RingBytes int
	// KillGrace bounds how long a SIGTERM'd container has to exit before
	// Kill escalates to SIGKILL. Zero applies the default (3s). Exposed so
	// tests can shorten it.
	KillGrace time.Duration
	// Registry is the hot-swappable registry client updated by SetRegistry RPC
	// and CLI handoff. Nil disables the RPC (returns Unimplemented).
	Registry *RegistryHub
}

// defaultKillGrace is the SIGTERM→SIGKILL escalation window used by both the
// Kill RPC and daemon Shutdown. It exists because a container init process
// (PID 1 of its PID namespace) that has not installed a signal handler never
// observes SIGTERM: the kernel discards fatal-default signals delivered to a
// child reaper, so `runc kill <id> SIGTERM` alone can leave such containers
// running indefinitely. SIGKILL is exempt from that rule, hence escalation.
const defaultKillGrace = 3 * time.Second

// Worker is the gRPC service object plus the in-memory context registry.
// The registry is never mutated in v0.1: Finished contexts stay listable
// and their logs stay readable until daemon exit (plan §8 / task spec).
type Worker struct {
	voilapb.UnimplementedWorkerServer

	cfg      Config
	hub      *eventHub
	launcher Launcher

	mu       sync.Mutex
	contexts map[string]*Context
	server   runServer // gRPC server (set by Serve)
}

// runServer is the minimal subset of *grpc.Server that Worker.Shutdown uses.
// Indirection makes testing Shutdown without a real gRPC server tractable.
type runServer interface {
	GracefulStop()
	Stop()
}

// NewWorker constructs a Worker with the given Config, applying defaults for
// unset fields. The returned Worker is ready to be registered with a
// grpc.Server (see server.go Serve).
func NewWorker(cfg Config) *Worker {
	if cfg.RingBytes == 0 {
		cfg.RingBytes = defaultRingBytes
	}
	if cfg.KillGrace <= 0 {
		cfg.KillGrace = defaultKillGrace
	}
	if cfg.Launcher == nil {
		cfg.Launcher = defaultPlatformLauncher(cfg)
	}
	return &Worker{
		cfg:      cfg,
		hub:      newEventHub(),
		launcher: cfg.Launcher,
		contexts: map[string]*Context{},
	}
}

// Launcher abstracts the "start / exec / kill a container" surface so the gRPC
// service logic is testable on darwin with a fake. The platform launcher
// (mount + bundle + runc) lives in launch_linux.go.
type Launcher interface {
	// Launch blocks until the container exits; it must call sink.Started(pid)
	// once the container init is running, route process output through
	// sink.Stdout/Stderr, and return the container's exit code (0..255).
	// Infrastructure failures return err with a zero code. Launch must NOT
	// abort on ctx cancellation alone — the worker uses WithoutCancel for
	// the launch so a client disconnect (which cancels the stream context)
	// does not kill the container; only Kill stops a context.
	Launch(ctx context.Context, spec LaunchSpec, sink IOSink) (int, error)
	// Exec blocks until the exec'd process exits, routing output through
	// sink. ctxID identifies the already-running context.
	Exec(ctx context.Context, ctxID string, spec ExecSpec, sink IOSink) (int, error)
	// Kill signals sig to the container's init process.
	Kill(ctx context.Context, ctxID string, sig syscall.Signal) error
}

// LaunchSpec is the post-resolution input to Launch.
type LaunchSpec struct {
	ID, Ref                string
	RootChunk, ConfigChunk chunkstore.ChunkID
	// Store, when non-nil, is the per-context ChunkStore the launcher must
	// read chunks through (mount.Load / mount.Mount / store.Get for the
	// image config). The worker wraps its cfg.Store in a CountingStore so
	// Stats() reflects exactly what the container touched; the launcher
	// must NOT Close the wrapper (the inner store is the daemon's shared
	// store; Close is the daemon's responsibility). When nil the launcher
	// falls back to its own cfg-bound store (e.g. a fake test launcher).
	Store            chunkstore.ChunkStore
	Args             []string
	MemoryLimitBytes int64
	CPUQuotaPercent  int
	Stdin            io.Reader
}

// ExecSpec is the input to Exec (the args + stdin for the additional process).
type ExecSpec struct {
	Args  []string
	Stdin io.Reader
}

// IOSink is how a Launcher reports the container's pid and routes output
// back to the worker. The worker implements it to (a) feed the ring buffer
// (Run only) and (b) forward bytes to the attached gRPC client stream while
// it stays connected.
type IOSink interface {
	Started(pid int)
	Stdout(p []byte)
	Stderr(p []byte)
}

// ----- Context registry helpers -----

// registerContext stores c in the registry keyed by its id. Caller must
// ensure uniqueness (generated ids are unique by construction).
func (w *Worker) registerContext(c *Context) {
	w.mu.Lock()
	w.contexts[c.id] = c
	w.mu.Unlock()
}

// getContext returns the registered context with id, or ok=false.
func (w *Worker) getContext(id string) (*Context, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	c, ok := w.contexts[id]
	return c, ok
}

// listContexts returns a snapshot of all registered contexts in unspecified
// order. v0.1 never deletes contexts, so a Finished context appears here.
func (w *Worker) listContexts() []*Context {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]*Context, 0, len(w.contexts))
	for _, c := range w.contexts {
		out = append(out, c)
	}
	return out
}

// newContextID returns "voila-<8 random hex chars>" (4 bytes of crypto/rand,
// 2^32 ids — well below birthday collision risk for short-lived daemons).
func newContextID() (string, error) {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return "voila-" + hex.EncodeToString(b[:]), nil
}

// ----- Run -----

// Run implements the Worker.Run RPC. First client message must be RunSpec;
// the first server message is the context id. Subsequent stdout/stderr
// frames flow until the container exits, when an exit_code frame terminates
// the stream. Client disconnect does NOT stop a context (detach semantics);
// output keeps flowing to the ring buffer and is available via Logs.
func (w *Worker) Run(stream voilapb.Worker_RunServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	specMsg := first.GetSpec()
	if specMsg == nil {
		return status.Error(codes.InvalidArgument, "first Run message must be a RunSpec")
	}
	spec := specMsg

	// Resolve image outside any context lock so concurrent Runs are not
	// serialized on resolution.
	resolved, err := w.cfg.Resolve(spec.GetImage())
	if err != nil {
		return status.Errorf(codes.InvalidArgument, "resolve image %q: %v", spec.GetImage(), err)
	}

	id, err := newContextID()
	if err != nil {
		return status.Errorf(codes.Internal, "allocate context id: %v", err)
	}
	ctx := newContext(id, resolved.Ref, w.hub, w.cfg.RingBytes)
	// Wrap the daemon's shared store so Stats() reports exactly what this
	// run's mount + image config reads touched (chunkstore.CountingStore
	// records distinct chunk ids + their logical byte lengths). nil cfg
	// store (tests / stub launcher) → no counter; List is nil-safe.
	//
	// When TraceDir is set, the store is first wrapped in a TraceStore so
	// every Get is logged to a per-run JSONL file (the CountingStore sits
	// outside and sees the same Gets). Trace creation failure is non-fatal:
	// the run proceeds untraced.
	var counting *chunkstore.CountingStore
	var tracing *chunkstore.TraceStore
	var tw *chunkstore.TraceWriter
	if w.cfg.Store != nil {
		store := w.cfg.Store
		if w.cfg.TraceDir != "" {
			path := filepath.Join(w.cfg.TraceDir, time.Now().UTC().Format("20060102T150405.000000")+"-"+id+".jsonl")
			if w2, err := chunkstore.NewTraceWriter(path); err != nil {
				log.Printf("voilad: trace %s: %v (running untraced)", path, err)
			} else {
				tw = w2
				tw.Emit(chunkstore.RunStartEvent{
					Type:    "run_start",
					TNS:     0,
					Wall:    time.Now().UTC().Format(time.RFC3339),
					Image:   resolved.Ref,
					Args:    spec.GetArgs(),
					Backend: MountBackend(),
				})
				tracing = chunkstore.NewTrace(store, tw)
				store = tracing
			}
		}
		counting = chunkstore.NewCounting(store)
	}
	ctx.setStatsSource(counting, resolved.ImageChunks, resolved.ImageBytes)
	w.registerContext(ctx)

	// First server message: the context id. Sent synchronously so any
	// subsequent stdout frames from the launcher goroutine are ordered after
	// it on the wire.
	if err := stream.Send(&voilapb.RunOutput{Output: &voilapb.RunOutput_ContextId{ContextId: id}}); err != nil {
		// Best-effort cleanup; the launch never started.
		_ = ctx.finish(-1)
		return err
	}

	// Stdin: io.Pipe fed by a Recv pump. If the client did not opt into
	// attaching stdin, close the write side immediately so the launcher
	// reads EOF and never blocks on stdin.
	stdinR, stdinW := io.Pipe()
	launchSpec := LaunchSpec{
		ID:               id,
		Ref:              resolved.Ref,
		RootChunk:        resolved.RootChunk,
		ConfigChunk:      resolved.ConfigChunk,
		Args:             spec.GetArgs(),
		MemoryLimitBytes: spec.GetMemoryLimitBytes(),
		CPUQuotaPercent:  int(spec.GetCpuQuotaPercent()),
		Stdin:            stdinR,
	}
	// Only thread the counting store when it was created (cfg.Store was
	// non-nil). A typed-nil pointer assigned to an interface field would
	// make spec.Store != nil even though the underlying store is nil (the
	// classic Go typed-nil pitfall), so we leave Store at its zero value
	// (true nil interface) when there is no counter.
	if counting != nil {
		launchSpec.Store = counting
	}

	// Sink writes stdout/stderr to the ring buffer AND, while the client is
	// still connected, to the gRPC stream. The launcher is responsible for
	// calling sink.Started(pid) which transitions the FSM to Running.
	// When tracing, the sink also emits the "exec" phase marker (container
	// init running) — the boundary between startup cost and workload cost.
	var sink IOSink = &runSink{
		ctx:    ctx,
		stream: stream,
	}
	if tw != nil {
		sink = &traceSink{IOSink: sink, tw: tw}
	}

	// Launch runs detached from the stream's context so a client disconnect
	// does not cancel the container (plan §8 detach semantics).
	launchCtx := context.WithoutCancel(stream.Context())
	type launchResult struct {
		code int
		err  error
	}
	done := make(chan launchResult, 1)
	go func() {
		code, lerr := w.launcher.Launch(launchCtx, launchSpec, sink)
		done <- launchResult{code, lerr}
	}()

	// Stdin pump. Runs concurrently with the launcher; closes the write
	// pipe on a client disconnect or an explicit stdin_eof. Errors here
	// surface as a closed pipe (read EOF) to the launcher, NOT as a launch
	// cancellation.
	stdinPumpDone := make(chan struct{})
	go func() {
		defer close(stdinPumpDone)
		runStdinPump(stream, stdinW)
	}()

	res := <-done

	// Terminal trace events: the "exit" phase marker, then run_end with the
	// trace + fetch counters. Close the writer before the stats/exit frames
	// so the file is complete on disk by the time the client sees the exit.
	if tw != nil {
		tw.Emit(chunkstore.PhaseEvent{Type: "phase", TNS: tw.TNS(), Name: "exit"})
		totals := chunkstore.RunEndTotals{}
		if tracing != nil {
			t := tracing.Totals()
			totals.Gets = t.Gets
			totals.Misses = t.Misses
			totals.DemandWaitNS = t.DemandWaitNS
			totals.PrefetchWaitNS = t.PrefetchWaitNS
		}
		if counting != nil {
			st := counting.Stats()
			totals.DistinctChunks = st.Chunks
			totals.DistinctBytes = st.Bytes
		}
		tw.Emit(chunkstore.RunEndEvent{Type: "run_end", TNS: tw.TNS(), Totals: totals})
		_ = tw.Close()
	}

	exitCode := res.code
	if res.err != nil {
		// Infrastructure failure: report a sentinel exit code and propagate
		// the error in the exit frame's presence; the client distinguishes a
		// crash from a clean exit by reading the trailer status. For v0.1 we
		// surface -1 as the code (the wire field is int32).
		if exitCode == 0 {
			exitCode = -1
		}
	}
	_ = ctx.finish(exitCode)
	// ctx.finish marks the ring finished so follow channels close after the
	// already-queued tail of stdout.

	// Stats frame: sent once, immediately before exit_code, populated from
	// the context's counting store (what the mount + image-config reads
	// touched) plus the resolved image totals. Omitted when the context
	// has no counter (nil-safe for old / fake launches).
	if fs := ctx.fetchStats(); fs != nil {
		_ = stream.Send(&voilapb.RunOutput{Output: &voilapb.RunOutput_Stats{Stats: fs}})
	}

	// Send the terminal exit_code frame BEFORE waiting for the stdin pump.
	// The client closes its send side once it sees exit_code, which unblocks
	// the server's stream.Recv() in runStdinPump and lets Run() return.
	// Waiting for stdinPumpDone first would deadlock when the client's stdin
	// pump is blocked reading the terminal (it never sends stdin_eof until
	// after exit_code arrives).
	_ = stream.Send(&voilapb.RunOutput{Output: &voilapb.RunOutput_ExitCode{ExitCode: int32(exitCode)}})

	// Unblock the stdin pump if it has not already exited (client may have
	// hung up on stdin but stayed connected for output; otherwise it exits
	// naturally on Recv error). Close is idempotent via pipe semantics.
	_ = stdinW.CloseWithError(io.EOF)
	<-stdinPumpDone

	if res.err != nil {
		return status.Errorf(codes.Aborted, "launch: %v", res.err)
	}
	return nil
}

// runStdinPump reads RunInput messages from stream and writes the stdin bytes
// to w (an io.Pipe writer) until either stdin_eof or a stream error (client
// disconnect / EOF). Closes w on exit so the launcher reads EOF.
func runStdinPump(stream voilapb.Worker_RunServer, w *io.PipeWriter) {
	defer func() { _ = w.CloseWithError(io.EOF) }()
	for {
		msg, err := stream.Recv()
		if err != nil {
			return
		}
		switch in := msg.Input.(type) {
		case *voilapb.RunInput_Stdin:
			if _, werr := w.Write(in.Stdin); werr != nil {
				return
			}
		case *voilapb.RunInput_StdinEof:
			return
		}
	}
}

// runSink is an IOSink that captures output into the context's ring buffer
// (so Logs/Logs-follow can replay it to later clients) and, while the gRPC
// client is still attached, forwards the same bytes to the Run stream. The
// stream send is best-effort: a client disconnect (stream.Context().Err())
// silences forwarding but ring capture continues.
//
// Concurrent SendMsg on a gRPC stream is not allowed, and the launcher's
// stdout and stderr arrive on separate goroutines (os/exec runs one copy
// goroutine per stream), so sends are serialized by sendMu. The exit_code
// frame is safe without it only because the Run handler sends it after the
// launcher (and both copy goroutines) have returned; it takes the lock anyway
// via sendLocked for uniformity.
type runSink struct {
	ctx    *Context
	stream voilapb.Worker_RunServer
	sendMu sync.Mutex
}

// Started transitions the context Scheduled → Running and records pid.
func (s *runSink) Started(pid int) { _ = s.ctx.start(pid) }

// traceSink wraps an IOSink and emits the "exec" trace phase marker when the
// launcher reports the container init running. All other methods delegate.
type traceSink struct {
	IOSink
	tw *chunkstore.TraceWriter
}

// Started emits the "exec" phase marker, then delegates.
func (s *traceSink) Started(pid int) {
	s.tw.Emit(chunkstore.PhaseEvent{Type: "phase", TNS: s.tw.TNS(), Name: "exec"})
	s.IOSink.Started(pid)
}

// Stdout appends p to the ring buffer and, while the client is attached,
// forwards it as a RunOutput_Stdout frame.
func (s *runSink) Stdout(p []byte) {
	if len(p) == 0 {
		return
	}
	s.ctx.ring.append(p, false, time.Now().UnixNano())
	s.sendLocked(&voilapb.RunOutput{Output: &voilapb.RunOutput_Stdout{Stdout: append([]byte(nil), p...)}})
}

// Stderr appends p to the ring buffer and, while the client is attached,
// forwards it as a RunOutput_Stderr frame.
func (s *runSink) Stderr(p []byte) {
	if len(p) == 0 {
		return
	}
	s.ctx.ring.append(p, true, time.Now().UnixNano())
	s.sendLocked(&voilapb.RunOutput{Output: &voilapb.RunOutput_Stderr{Stderr: append([]byte(nil), p...)}})
}

// sendLocked forwards a frame to the client stream under sendMu, dropping it
// silently once the client has disconnected.
func (s *runSink) sendLocked(msg *voilapb.RunOutput) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.stream.Context().Err() == nil {
		_ = s.stream.Send(msg)
	}
}

// ----- Exec -----

// Exec implements the Worker.Exec RPC. The first message must be an ExecSpec
// naming a *running* context. Output goes only to the attached client stream
// (NOT into the ring buffer — only the main process's output is captured;
// documented). Detach semantics apply like Run.
func (w *Worker) Exec(stream voilapb.Worker_ExecServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	specMsg := first.GetSpec()
	if specMsg == nil {
		return status.Error(codes.InvalidArgument, "first Exec message must be an ExecSpec")
	}
	if specMsg.GetContextId() == "" {
		return status.Error(codes.InvalidArgument, "ExecSpec.context_id is required")
	}
	if len(specMsg.GetArgs()) == 0 {
		return status.Error(codes.InvalidArgument, "ExecSpec.args must be non-empty")
	}
	ctx, ok := w.getContext(specMsg.GetContextId())
	if !ok {
		return status.Errorf(codes.NotFound, "no context %q", specMsg.GetContextId())
	}
	if ctx.statusString() != StatusRunning {
		return status.Errorf(codes.FailedPrecondition, "context %q is not running (status=%s)", specMsg.GetContextId(), ctx.statusString())
	}

	stdinR, stdinW := io.Pipe()
	execSpec := ExecSpec{
		Args:  specMsg.GetArgs(),
		Stdin: stdinR,
	}
	sink := &execSink{stream: stream}

	execCtx := context.WithoutCancel(stream.Context())
	type execResult struct {
		code int
		err  error
	}
	done := make(chan execResult, 1)
	go func() {
		code, eerr := w.launcher.Exec(execCtx, specMsg.GetContextId(), execSpec, sink)
		done <- execResult{code, eerr}
	}()

	stdinPumpDone := make(chan struct{})
	go func() {
		defer close(stdinPumpDone)
		execStdinPump(stream, stdinW)
	}()

	res := <-done
	_ = stdinW.CloseWithError(io.EOF)
	<-stdinPumpDone

	exitCode := res.code
	if res.err != nil && exitCode == 0 {
		exitCode = -1
	}
	_ = stream.Send(&voilapb.ExecOutput{Output: &voilapb.ExecOutput_ExitCode{ExitCode: int32(exitCode)}})
	if res.err != nil {
		return status.Errorf(codes.Aborted, "exec: %v", res.err)
	}
	return nil
}

// execStdinPump mirrors runStdinPump for the Exec stream shape.
func execStdinPump(stream voilapb.Worker_ExecServer, w *io.PipeWriter) {
	defer func() { _ = w.CloseWithError(io.EOF) }()
	for {
		msg, err := stream.Recv()
		if err != nil {
			return
		}
		switch in := msg.Input.(type) {
		case *voilapb.ExecInput_Stdin:
			if _, werr := w.Write(in.Stdin); werr != nil {
				return
			}
		case *voilapb.ExecInput_StdinEof:
			return
		}
	}
}

// execSink is an IOSink for Exec: output flows only to the stream (the ring
// buffer deliberately excludes exec output — documented — to keep Logs
// semantics simple and predictable). sendMu serializes SendMsg for the same
// reason as runSink (stdout/stderr arrive on separate copy goroutines).
type execSink struct {
	stream voilapb.Worker_ExecServer
	sendMu sync.Mutex
}

func (s *execSink) Started(int) {} // not reported for exec processes

func (s *execSink) Stdout(p []byte) {
	if len(p) == 0 {
		return
	}
	s.sendLocked(&voilapb.ExecOutput{Output: &voilapb.ExecOutput_Stdout{Stdout: append([]byte(nil), p...)}})
}

func (s *execSink) Stderr(p []byte) {
	if len(p) == 0 {
		return
	}
	s.sendLocked(&voilapb.ExecOutput{Output: &voilapb.ExecOutput_Stderr{Stderr: append([]byte(nil), p...)}})
}

func (s *execSink) sendLocked(msg *voilapb.ExecOutput) {
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	if s.stream.Context().Err() == nil {
		_ = s.stream.Send(msg)
	}
}

// ----- Logs -----

// Logs implements the Worker.Logs RPC: replays the context's ring buffer as
// LogChunk messages and, when follow=true, streams new chunks until the
// context finishes (or the client cancels). Unknown context → NotFound.
// The replay+follow boundary is atomic so a follower sees neither a gap nor
// a duplicate of chunks appended immediately after subscribe (see ring.go).
func (w *Worker) Logs(req *voilapb.LogsRequest, stream voilapb.Worker_LogsServer) error {
	ctx, ok := w.getContext(req.GetContextId())
	if !ok {
		return status.Errorf(codes.NotFound, "no context %q", req.GetContextId())
	}

	if !req.GetFollow() {
		for _, c := range ctx.ring.replay() {
			if err := stream.Send(chunkToLogChunk(c)); err != nil {
				return err
			}
		}
		return nil
	}

	snapshot, out := ctx.ring.replayAndFollow(stream.Context().Done())
	for _, c := range snapshot {
		if err := stream.Send(chunkToLogChunk(c)); err != nil {
			return err
		}
	}
	for {
		select {
		case c, ok := <-out:
			if !ok {
				return nil
			}
			if err := stream.Send(chunkToLogChunk(c)); err != nil {
				return err
			}
		case <-stream.Context().Done():
			return nil
		}
	}
}

// chunkToLogChunk converts an internal ringChunk into its wire form.
func chunkToLogChunk(c ringChunk) *voilapb.LogChunk {
	return &voilapb.LogChunk{
		Data:        append([]byte(nil), c.data...),
		Stderr:      c.stderr,
		TimestampNs: c.tsNs,
	}
}

// ----- Events -----

// Events implements the Worker.Events RPC: subscribes to the hub (optionally
// filtered by context_id) and streams new Event messages until the client
// cancels. Past events are NOT replayed on subscribe (plan §8: clients
// subscribe, never poll; documented).
func (w *Worker) Events(req *voilapb.EventsRequest, stream voilapb.Worker_EventsServer) error {
	ch, cancel := w.hub.subscribe(req.GetContextId())
	defer cancel()
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				return nil
			}
			if err := stream.Send(ev); err != nil {
				return err
			}
		case <-stream.Context().Done():
			return nil
		}
	}
}

// ----- List -----

// List implements the Worker.List RPC: a snapshot of all registered
// contexts regardless of state (v0.1 never deletes; Finished contexts stay
// listable until daemon exit).
func (w *Worker) List(ctx context.Context, _ *voilapb.ListRequest) (*voilapb.ListResponse, error) {
	contexts := w.listContexts()
	out := &voilapb.ListResponse{Contexts: make([]*voilapb.ContextInfo, 0, len(contexts))}
	for _, c := range contexts {
		out.Contexts = append(out.Contexts, snapshotToInfo(c.snapshot()))
	}
	return out, nil
}

// snapshotToInfo projects a Context's Snapshot to its wire form, including
// the live fetch stats (nil when the context has no counter, e.g. old / fake
// launches or a nil cfg store).
func snapshotToInfo(s Snapshot) *voilapb.ContextInfo {
	info := &voilapb.ContextInfo{
		Id:        s.ID,
		ImageRef:  s.Ref,
		Status:    string(s.Status),
		StartedNs: s.StartedNs,
		Pid:       int32(s.PID),
		ExitCode:  int32(s.ExitCode),
	}
	if s.Stats != nil {
		info.Stats = s.Stats
	}
	return info
}

// ----- Kill -----

// Kill implements the Worker.Kill RPC. Signal 0 maps to SIGTERM. The
// context must be Running (a Scheduled/Finished context returns
// FailedPrecondition). SIGTERM is delivered with a grace window and
// escalates to SIGKILL if the container is still running (see killOne);
// any other signal is forwarded directly. The resulting container exit
// surfaces as an exit_code frame on any attached stream and as a Finished
// event on the hub.
func (w *Worker) Kill(ctx context.Context, req *voilapb.KillRequest) (*voilapb.KillResponse, error) {
	c, ok := w.getContext(req.GetContextId())
	if !ok {
		return nil, status.Errorf(codes.NotFound, "no context %q", req.GetContextId())
	}
	if st := c.statusString(); st != StatusRunning {
		return nil, status.Errorf(codes.FailedPrecondition, "context %q is not running (status=%s)", req.GetContextId(), st)
	}
	sig := syscall.Signal(req.GetSignal())
	if sig == 0 {
		sig = syscall.SIGTERM
	}
	if err := w.killOne(ctx, req.GetContextId(), sig); err != nil {
		return nil, status.Errorf(codes.Aborted, "kill %q: %v", req.GetContextId(), err)
	}
	return &voilapb.KillResponse{}, nil
}

// SetRegistry updates the daemon's registry URL and bearer token from CLI
// handoff. Chunk GETs remain unauthenticated on the wire; the token is used
// only for manifest auto-pull and authenticated registry endpoints.
func (w *Worker) SetRegistry(_ context.Context, req *voilapb.SetRegistryRequest) (*voilapb.SetRegistryResponse, error) {
	if w.cfg.Registry == nil {
		return nil, status.Error(codes.Unimplemented, "registry handoff not configured")
	}
	if err := w.cfg.Registry.Configure(req.GetRegistryUrl(), req.GetToken()); err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "registry: %v", err)
	}
	return &voilapb.SetRegistryResponse{}, nil
}

// killOne delivers sig to one running context. SIGTERM gets a grace window
// (cfg.KillGrace, or until ctx is cancelled) and escalates to SIGKILL when
// the container still appears Running — a PID-namespaced init without a
// handler silently discards SIGTERM, so escalation is what makes the default
// kill reliable. Other signals return after delivery.
func (w *Worker) killOne(ctx context.Context, id string, sig syscall.Signal) error {
	if err := w.launcher.Kill(ctx, id, sig); err != nil {
		return err
	}
	if sig != syscall.SIGTERM {
		return nil
	}
	grace := w.cfg.KillGrace
	if grace <= 0 {
		grace = defaultKillGrace
	}
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-timer.C:
	case <-ctx.Done():
	}
	// Only escalate if the context still appears running.
	if c, ok := w.getContext(id); ok && c.statusString() == StatusRunning {
		return w.launcher.Kill(ctx, id, syscall.SIGKILL)
	}
	return nil
}

// BuildRun implements Worker.BuildRun: execute one Dockerfile RUN step and
// return the snapshot layer manifest chunk.
func (w *Worker) BuildRun(stream voilapb.Worker_BuildRunServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	specMsg := first.GetSpec()
	if specMsg == nil {
		return status.Error(codes.InvalidArgument, "first BuildRun message must be a BuildRunSpec")
	}
	if len(specMsg.GetArgv()) == 0 {
		return status.Error(codes.InvalidArgument, "BuildRunSpec.argv must be non-empty")
	}
	var rootChunk, configChunk chunkstore.ChunkID
	if len(specMsg.GetRootChunk()) == len(rootChunk) {
		copy(rootChunk[:], specMsg.GetRootChunk())
	}
	if len(specMsg.GetConfigChunk()) == len(configChunk) {
		copy(configChunk[:], specMsg.GetConfigChunk())
	}

	stdinR, stdinW := io.Pipe()
	go buildRunStdinPump(stream, stdinW)

	sink := &buildRunSink{stream: stream}
	launchCtx := context.WithoutCancel(stream.Context())
	pl, ok := w.launcher.(*platformLauncher)
	if !ok {
		return status.Error(codes.Unimplemented, "BuildRun requires the linux platform launcher")
	}
	layerChunk, code, err := pl.BuildRun(launchCtx, BuildRunSpec{
		RootChunk:   rootChunk,
		ConfigChunk: configChunk,
		Argv:        specMsg.GetArgv(),
		Env:         specMsg.GetEnv(),
		Cwd:         specMsg.GetCwd(),
		User:        specMsg.GetUser(),
		HostNetwork: true,
		Stdin:       stdinR,
	}, sink)
	_ = stdinW.CloseWithError(io.EOF)

	if err != nil {
		return status.Errorf(codes.Aborted, "build run: %v", err)
	}
	if code == 0 && layerChunk != (chunkstore.ChunkID{}) {
		_ = stream.Send(&voilapb.BuildRunOutput{
			Output: &voilapb.BuildRunOutput_LayerManifestChunk{
				LayerManifestChunk: layerChunk[:],
			},
		})
	}
	_ = stream.Send(&voilapb.BuildRunOutput{
		Output: &voilapb.BuildRunOutput_ExitCode{ExitCode: int32(code)},
	})
	return nil
}

func buildRunStdinPump(stream voilapb.Worker_BuildRunServer, w *io.PipeWriter) {
	defer func() { _ = w.CloseWithError(io.EOF) }()
	for {
		msg, err := stream.Recv()
		if err != nil {
			return
		}
		switch in := msg.Input.(type) {
		case *voilapb.BuildRunInput_Stdin:
			if _, werr := w.Write(in.Stdin); werr != nil {
				return
			}
		case *voilapb.BuildRunInput_StdinEof:
			return
		}
	}
}

type buildRunSink struct {
	stream voilapb.Worker_BuildRunServer
	sendMu sync.Mutex
}

func (s *buildRunSink) Started(pid int) {}
func (s *buildRunSink) Stdout(p []byte) {
	if len(p) == 0 {
		return
	}
	s.sendMu.Lock()
	_ = s.stream.Send(&voilapb.BuildRunOutput{Output: &voilapb.BuildRunOutput_Stdout{Stdout: append([]byte(nil), p...)}})
	s.sendMu.Unlock()
}
func (s *buildRunSink) Stderr(p []byte) {
	if len(p) == 0 {
		return
	}
	s.sendMu.Lock()
	_ = s.stream.Send(&voilapb.BuildRunOutput{Output: &voilapb.BuildRunOutput_Stderr{Stderr: append([]byte(nil), p...)}})
	s.sendMu.Unlock()
}

// ----- Shutdown -----

// Shutdown gracefully tears the daemon down: signals every Running context
// (SIGTERM → grace → SIGKILL), then stops the gRPC server. It blocks until
// the server has stopped. ctx bounds the SIGTERM→SIGKILL grace period; a
// cancelled ctx escalates immediately to SIGKILL.
//
// The running-context snapshot is taken once at entry so Kill and the FSM
// transitions do not race Shutdown's iteration.
func (w *Worker) Shutdown(ctx context.Context) {
	running := w.runningContexts()
	var wg sync.WaitGroup
	for _, c := range running {
		wg.Add(1)
		go func(c *Context) {
			defer wg.Done()
			w.shutdownOne(ctx, c)
		}(c)
	}
	wg.Wait()

	if w.server != nil {
		// Give in-flight RPCs a brief grace, then hard-stop. GracefulStop
		// blocks; we time-box it via the ctx deadline is not directly
		// supported, so we run it on a goroutine and Stop() if ctx fires.
		stopped := make(chan struct{})
		go func() {
			w.server.GracefulStop()
			close(stopped)
		}()
		select {
		case <-stopped:
		case <-ctx.Done():
			w.server.Stop()
			<-stopped
		}
	}
}

// shutdownOne signals one Running context (SIGTERM, escalating to SIGKILL
// after the grace window via killOne) so the container dies before daemon
// exit. The launcher's Launch goroutine returns once the container dies,
// which the Run RPC handler observes as a normal exit.
func (w *Worker) shutdownOne(ctx context.Context, c *Context) {
	_ = w.killOne(ctx, c.id, syscall.SIGTERM)
}

// runningContexts returns a snapshot of all contexts currently in the
// Running state. Used by Shutdown.
func (w *Worker) runningContexts() []*Context {
	all := w.listContexts()
	out := make([]*Context, 0, len(all))
	for _, c := range all {
		if c.statusString() == StatusRunning {
			out = append(out, c)
		}
	}
	return out
}
