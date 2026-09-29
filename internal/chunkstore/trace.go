// trace.go implements access tracing: a TraceStore wrapper that logs every
// Get (chunk id, hit/miss, wait time, demand/prefetch source) to a local
// JSONL file, one file per container run. The format is meant to be
// explored with jq / duckdb / pandas — no custom tooling required.
//
// The trace answers "why is cold start slow": when did reads block on the
// store, which of those were remote-fetch misses, and how do misses
// distribute relative to the run's phase markers (exec → exit).
//
// Hit/miss classification uses Stat before Get: Stat is local-only by the
// interface contract (it never fetches), so a chunk absent from Stat that
// then succeeds at Get went through a remote fetch (under CachedStore) —
// that is exactly a cold-start miss. This keeps TraceStore correct no
// matter how the store is composed (plain LocalStore → everything is a hit).
package chunkstore

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"sync"
	"time"
)

// Trace event sources (the "source" field on get events).
const (
	// SourceDemand is a Get driven by a blocked reader (a read syscall,
	// mount/config load). This is the latency that matters.
	SourceDemand = "demand"
	// SourcePrefetch is a Get driven by a background prefetch goroutine
	// (whole-file prefetch in the FUSE/NBD backends). Separating it from
	// demand keeps self-inflicted prefetch traffic out of the latency
	// picture.
	SourcePrefetch = "prefetch"
)

type sourceCtxKey struct{}

// WithSource tags ctx with a trace source (SourceDemand / SourcePrefetch).
// The two prefetch sites (mount.FileReader.prefetch, nbd prefetchFile) use
// it so their Gets are not mistaken for workload latency.
func WithSource(ctx context.Context, source string) context.Context {
	return context.WithValue(ctx, sourceCtxKey{}, source)
}

// traceSource extracts the source tag, defaulting to SourceDemand.
func traceSource(ctx context.Context) string {
	if s, ok := ctx.Value(sourceCtxKey{}).(string); ok && s != "" {
		return s
	}
	return SourceDemand
}

// ----- Events (one JSON object per line) -----

// RunStartEvent is the first line of every trace file.
type RunStartEvent struct {
	Type    string   `json:"type"` // "run_start"
	TNS     int64    `json:"t_ns"`
	Wall    string   `json:"wall"`    // RFC3339 wall clock of run start
	Image   string   `json:"image"`   // resolved image ref
	Args    []string `json:"args"`    // container argv
	Backend string   `json:"backend"` // mount backend (fuse / erofs+nbd)
}

// PhaseEvent marks a lifecycle point ("exec" = container init running,
// "exit" = container exited). Misses before "exec" are mount/startup cost;
// misses after it are workload latency.
type PhaseEvent struct {
	Type string `json:"type"` // "phase"
	TNS  int64  `json:"t_ns"`
	Name string `json:"name"`
}

// GetEvent is one store Get. Result is "hit" (served locally) or "miss"
// (required a remote fetch). WaitNS is how long the Get caller was blocked;
// Bytes is the logical (uncompressed) chunk size.
type GetEvent struct {
	Type   string `json:"type"` // "get"
	TNS    int64  `json:"t_ns"`
	Chunk  string `json:"chunk"`
	Result string `json:"result"` // "hit" | "miss"
	WaitNS int64  `json:"wait_ns"`
	Bytes  int    `json:"bytes"`
	Source string `json:"source"` // "demand" | "prefetch"
}

// RunEndTotals is the summary payload of the terminal run_end event.
type RunEndTotals struct {
	Gets           uint64 `json:"gets"`
	Misses         uint64 `json:"misses"`
	DemandWaitNS   int64  `json:"demand_wait_ns"`   // total blocked time, demand Gets
	PrefetchWaitNS int64  `json:"prefetch_wait_ns"` // total blocked time, prefetch Gets
	DistinctChunks uint64 `json:"distinct_chunks"`  // distinct chunks served (0 = no counter)
	DistinctBytes  uint64 `json:"distinct_bytes"`   // logical bytes of those chunks
}

// RunEndEvent is the last line of every trace file.
type RunEndEvent struct {
	Type   string       `json:"type"` // "run_end"
	TNS    int64        `json:"t_ns"`
	Totals RunEndTotals `json:"totals"`
}

// ----- Writer -----

// TraceWriter appends events to a JSONL file. Timestamps are relative to
// construction (monotonic); the wall clock is recorded once in run_start.
// Safe for concurrent use (FUSE reads arrive on many goroutines).
type TraceWriter struct {
	mu    sync.Mutex
	buf   *bufio.Writer
	f     *os.File
	start time.Time
}

// NewTraceWriter creates path (truncating) and returns a writer whose t_ns
// clock starts now.
func NewTraceWriter(path string) (*TraceWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	return &TraceWriter{buf: bufio.NewWriter(f), f: f, start: time.Now()}, nil
}

// TNS returns nanoseconds since the writer was created — the value every
// event stamps into t_ns.
func (w *TraceWriter) TNS() int64 { return time.Since(w.start).Nanoseconds() }

// Emit marshals v as one JSON line. The caller sets Type/TNS (use TNS()).
// Errors are swallowed: tracing must never break a run.
func (w *TraceWriter) Emit(v any) {
	line, err := json.Marshal(v)
	if err != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_, _ = w.buf.Write(line)
	_ = w.buf.WriteByte('\n')
}

// Close flushes and closes the file. Idempotent.
func (w *TraceWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.buf == nil {
		return nil
	}
	_ = w.buf.Flush()
	w.buf = nil
	return w.f.Close()
}

// ----- Store -----

// TraceStore wraps a ChunkStore and emits a GetEvent per successful Get,
// keeping running totals for the run_end event. Classification: Stat before
// Get (local-only by contract) — absent at Stat + success at Get = "miss".
//
// Safe for concurrent use.
type TraceStore struct {
	inner ChunkStore
	tw    *TraceWriter

	mu           sync.Mutex
	gets         uint64
	misses       uint64
	demandWait   int64
	prefetchWait int64
}

// NewTrace wraps inner so every Get is logged to tw.
func NewTrace(inner ChunkStore, tw *TraceWriter) *TraceStore {
	return &TraceStore{inner: inner, tw: tw}
}

// TraceTotals is a point-in-time snapshot of the TraceStore counters.
type TraceTotals struct {
	Gets, Misses                 uint64
	DemandWaitNS, PrefetchWaitNS int64
}

// Totals returns a snapshot of the counters.
func (c *TraceStore) Totals() TraceTotals {
	c.mu.Lock()
	defer c.mu.Unlock()
	return TraceTotals{c.gets, c.misses, c.demandWait, c.prefetchWait}
}

// Get times the inner Get, classifies hit/miss via a prior Stat, emits a
// GetEvent, and updates totals. Failed Gets are not recorded (a trace is a
// latency/loading picture, not an error log).
func (c *TraceStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	_, local := c.inner.Stat(id)
	start := time.Now()
	b, err := c.inner.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	wait := time.Since(start)
	src := traceSource(ctx)
	result := "hit"
	if !local {
		result = "miss"
	}
	c.tw.Emit(GetEvent{
		Type:   "get",
		TNS:    c.tw.TNS(),
		Chunk:  id.String(),
		Result: result,
		WaitNS: wait.Nanoseconds(),
		Bytes:  len(b),
		Source: src,
	})
	c.mu.Lock()
	c.gets++
	if !local {
		c.misses++
	}
	if src == SourcePrefetch {
		c.prefetchWait += wait.Nanoseconds()
	} else {
		c.demandWait += wait.Nanoseconds()
	}
	c.mu.Unlock()
	return b, nil
}

// Put delegates; writes are not traced.
func (c *TraceStore) Put(buf []byte) (ChunkID, error) { return c.inner.Put(buf) }

// Stat delegates; Stat never fetches and is not traced.
func (c *TraceStore) Stat(id ChunkID) (ChunkMeta, bool) { return c.inner.Stat(id) }

// GC delegates.
func (c *TraceStore) GC(reachable map[ChunkID]struct{}) (int, error) {
	return c.inner.GC(reachable)
}

// Close delegates. The inner store is typically shared (the daemon's global
// store); callers that do not own it should not Close through the wrapper.
func (c *TraceStore) Close() error { return c.inner.Close() }

var _ ChunkStore = (*TraceStore)(nil)
