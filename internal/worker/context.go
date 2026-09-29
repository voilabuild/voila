package worker

import (
	"errors"
	"sync"
	"time"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"
)

// ContextStatus is the lifecycle state of a run context (plan §8 / task spec
// §8 context.go). States flow Scheduled → Running → Finished; Finished is
// terminal. The string form mirrors the wire status field of ContextInfo so
// callers do not need a separate mapping table.
type ContextStatus string

const (
	StatusScheduled ContextStatus = "scheduled"
	StatusRunning   ContextStatus = "running"
	StatusFinished  ContextStatus = "finished"
)

// Context is a single voila run context: its FSM, ring buffer, and the
// metadata surfaced via List/Kill/Logs. A Context is owned by the Worker
// registry; v0.1 never deletes contexts (Finished contexts remain listable
// and their logs remain readable until daemon exit).
//
// All public methods are safe for concurrent use; state transitions are
// guarded and emit a lifecycle Event through the shared hub as well as
// update the in-memory record (status/pid/exit code) surfaced by List.
type Context struct {
	id  string
	ref string

	mu        sync.Mutex
	status    ContextStatus
	startedNs int64
	pid       int
	exitCode  int

	// statsSource holds the per-context fetch counter + the resolved image
	// totals. Set once before the context is launched (via setStatsSource)
	// and read by Snapshot / fetchStats for the live List snapshot and the
	// post-run Stats frame. A nil counting store means "no counter" (e.g.
	// old / fake launches without a daemon store); stats-related accessors
	// are nil-safe in that case.
	statsMu     sync.Mutex
	counting    *chunkstore.CountingStore
	imageChunks uint64
	imageBytes  uint64

	ring *ring
	hub  *eventHub
}

// newContext constructs a Context in the Scheduled state and emits the
// SCHEDULED event through the hub. The caller is responsible for registering
// the returned context in the worker's registry.
func newContext(id, ref string, hub *eventHub, ringBudget int) *Context {
	c := &Context{
		id:     id,
		ref:    ref,
		status: StatusScheduled,
		ring:   newRing(ringBudget),
		hub:    hub,
	}
	c.emit(voilapb.EventType_EVENT_TYPE_SCHEDULED, 0)
	return c
}

// ErrIllegalTransition is returned when a transition is requested from a
// state that the FSM does not permit.
var ErrIllegalTransition = errors.New("worker: illegal context transition")

// ErrAlreadyFinished is returned by start when the context is already in the
// Finished state (a finish-on-launch-failure raced a late Started callback).
var ErrAlreadyFinished = errors.New("worker: context already finished")

// start transitions Scheduled → Running, recording the container init pid.
// Returns ErrIllegalTransition from any non-Scheduled state, ErrAlreadyFinished
// if the context already finished.
func (c *Context) start(pid int) error {
	c.mu.Lock()
	if c.status == StatusFinished {
		c.mu.Unlock()
		return ErrAlreadyFinished
	}
	if c.status != StatusScheduled {
		c.mu.Unlock()
		return ErrIllegalTransition
	}
	c.status = StatusRunning
	c.pid = pid
	c.startedNs = time.Now().UnixNano()
	c.mu.Unlock()
	// Emit outside c.mu so subscribers' drain goroutines, which may call
	// back into a Snapshot (e.g. a future List-from-subscriber), cannot
	// self-deadlock. The hub itself takes only its own mutex.
	c.emit(voilapb.EventType_EVENT_TYPE_STARTED, 0)
	return nil
}

// finish transitions any non-finished state → Finished, recording the exit
// code. It also drains the ring follower subscriptions by marking the ring
// finished (callers' follow channels close once the queue is flushed).
// finish is idempotent: re-calling returns ErrAlreadyFinished.
func (c *Context) finish(exitCode int) error {
	c.mu.Lock()
	if c.status == StatusFinished {
		c.mu.Unlock()
		return ErrAlreadyFinished
	}
	c.status = StatusFinished
	c.exitCode = exitCode
	// pid is no longer live; clear it so List surfaces pid=0 once finished.
	c.pid = 0
	c.mu.Unlock()

	c.emit(voilapb.EventType_EVENT_TYPE_FINISHED, int32(exitCode))
	c.ring.finish()
	return nil
}

// Snapshot is an immutable projection of the Context at a point in time;
// it backs the List RPC and is also used internally by Kill. Stats carries
// the live fetch counters (nil when the context has no counter).
type Snapshot struct {
	ID        string
	Ref       string
	Status    ContextStatus
	StartedNs int64
	PID       int
	ExitCode  int
	Stats     *voilapb.FetchStats
}

// snapshot returns a consistent Snapshot of the context's current state.
// The fetch stats are snapshotted under statsMu (independent of the FSM
// mutex) so a concurrent mount read does not block List.
func (c *Context) snapshot() Snapshot {
	c.mu.Lock()
	s := Snapshot{
		ID:        c.id,
		Ref:       c.ref,
		Status:    c.status,
		StartedNs: c.startedNs,
		PID:       c.pid,
		ExitCode:  c.exitCode,
	}
	c.mu.Unlock()
	s.Stats = c.snapshotStats()
	return s
}

// setStatsSource records the per-context counting store + image totals. Must
// be called exactly once, before the launcher runs. A nil counting store is
// valid (the context then reports no stats).
func (c *Context) setStatsSource(counting *chunkstore.CountingStore, imageChunks, imageBytes uint64) {
	c.statsMu.Lock()
	c.counting = counting
	c.imageChunks = imageChunks
	c.imageBytes = imageBytes
	c.statsMu.Unlock()
}

// fetchStats returns a *voilapb.FetchStats snapshot for the post-run Stats
// frame, or nil when the context has no counter.
func (c *Context) fetchStats() *voilapb.FetchStats {
	c.statsMu.Lock()
	counting := c.counting
	imageChunks := c.imageChunks
	imageBytes := c.imageBytes
	c.statsMu.Unlock()
	if counting == nil {
		return nil
	}
	st := counting.Stats()
	return &voilapb.FetchStats{
		ChunksFetched: st.Chunks,
		BytesFetched:  st.Bytes,
		ImageChunks:   imageChunks,
		ImageBytes:    imageBytes,
	}
}

// snapshotStats is the List path's nil-safe view of the live stats.
func (c *Context) snapshotStats() *voilapb.FetchStats {
	return c.fetchStats()
}

// running reports whether the context is in the Running state.
func (c *Context) running() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status == StatusRunning
}

// statusString returns the current status string; used for cheap checks
// (e.g. Kill's non-running precondition).
func (c *Context) statusString() ContextStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status
}

// emit publishes an Event for this context through the shared hub. Called
// outside of c.mu (callers release the lock first).
func (c *Context) emit(typ voilapb.EventType, exitCode int32) {
	c.hub.publish(newEvent(c.id, typ, exitCode))
}
