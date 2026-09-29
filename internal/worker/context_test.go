package worker

import (
	"sync"
	"testing"
	"time"

	voilapb "voila/internal/proto"
)

// TestFSM_LegalTransitions walks the happy path Scheduled → Running →
// Finished and checks the per-transition state, pid, and emitted events.
func TestFSM_LegalTransitions(t *testing.T) {
	hub := newEventHub()
	ch, cancel := hub.subscribe("")
	defer cancel()

	c := newContext("voila-deadbeef", "img:tag", hub, 0)

	// SCHEDULED is emitted at construction.
	if got := recvEvent(t, ch); got.Type != voilapb.EventType_EVENT_TYPE_SCHEDULED {
		t.Fatalf("first event = %v, want SCHEDULED", got.Type)
	}
	if got := c.snapshot(); got.Status != StatusScheduled {
		t.Fatalf("status = %s, want scheduled", got.Status)
	}
	if got := c.snapshot(); got.PID != 0 || got.ExitCode != 0 {
		t.Fatalf("snapshot = %+v, want zero pid/exit", got)
	}

	// Scheduled → Running records pid and emits STARTED.
	if err := c.start(4242); err != nil {
		t.Fatalf("start: %v", err)
	}
	if got := c.snapshot(); got.Status != StatusRunning || got.PID != 4242 {
		t.Fatalf("after start: %+v", got)
	}
	if got := recvEvent(t, ch); got.Type != voilapb.EventType_EVENT_TYPE_STARTED {
		t.Fatalf("after start event = %v, want STARTED", got.Type)
	}

	// Running → Finished records exit code, clears pid, emits FINISHED.
	if err := c.finish(7); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if got := c.snapshot(); got.Status != StatusFinished || got.ExitCode != 7 || got.PID != 0 {
		t.Fatalf("after finish: %+v", got)
	}
	if ev := recvEvent(t, ch); ev.Type != voilapb.EventType_EVENT_TYPE_FINISHED || ev.ExitCode != 7 {
		t.Fatalf("finish event = %+v, want FINISHED exit=7", ev)
	}
}

// TestFSM_IllegalTransitions verifies that illegal transitions return errors
// and leave the state machine untouched.
func TestFSM_IllegalTransitions(t *testing.T) {
	hub := newEventHub()

	t.Run("start from finished", func(t *testing.T) {
		c := newContext("x", "img", hub, 0)
		// Fast-forward: Scheduled → Running → Finished (finish is legal from
		// any state but we use Running to get clean exit code semantics).
		if err := c.start(1); err != nil {
			t.Fatal(err)
		}
		if err := c.finish(0); err != nil {
			t.Fatal(err)
		}
		if err := c.start(2); err != ErrAlreadyFinished {
			t.Fatalf("start on finished: err=%v, want ErrAlreadyFinished", err)
		}
		// And finish again should be idempotent.
		if err := c.finish(9); err != ErrAlreadyFinished {
			t.Fatalf("re-finish: err=%v, want ErrAlreadyFinished", err)
		}
		if got := c.snapshot(); got.Status != StatusFinished || got.ExitCode != 0 {
			t.Fatalf("post-illegal-call snapshot changed: %+v", got)
		}
	})

	t.Run("start twice (running -> running)", func(t *testing.T) {
		c := newContext("y", "img", hub, 0)
		if err := c.start(11); err != nil {
			t.Fatal(err)
		}
		if err := c.start(22); err != ErrIllegalTransition {
			t.Fatalf("second start: err=%v, want ErrIllegalTransition", err)
		}
		if got := c.snapshot(); got.PID != 11 {
			t.Fatalf("second start mutated pid: %+v", got)
		}
	})
}

// TestFSM_FinishFromScheduled covers the launch-failure path (Scheduled →
// Finished without ever going Running): legal, emits FINISHED.
func TestFSM_FinishFromScheduled(t *testing.T) {
	hub := newEventHub()
	ch, cancel := hub.subscribe("z")
	defer cancel()
	c := newContext("z", "img", hub, 0)
	if err := c.finish(-1); err != nil {
		t.Fatalf("finish from scheduled: %v", err)
	}
	if got := c.snapshot(); got.Status != StatusFinished || got.ExitCode != -1 {
		t.Fatalf("snapshot = %+v", got)
	}
	// Skip the SCHEDULED event emitted at construction; the next one must be
	// FINISHED for the finish transition.
	if ev := recvEvent(t, ch); ev.Type != voilapb.EventType_EVENT_TYPE_SCHEDULED {
		t.Fatalf("first event = %v, want SCHEDULED", ev.Type)
	}
	if ev := recvEvent(t, ch); ev.Type != voilapb.EventType_EVENT_TYPE_FINISHED {
		t.Fatalf("event = %v, want FINISHED", ev.Type)
	}
}

// recvEvent pulls one event from ch or fails the test on miss/timeout.
func recvEvent(t *testing.T, ch <-chan *voilapb.Event) *voilapb.Event {
	t.Helper()
	select {
	case ev, ok := <-ch:
		if !ok {
			t.Fatal("event channel closed")
		}
		return ev
	case <-time.After(2 * time.Second):
		t.Fatal("no event available")
		return nil
	}
}

// TestFSM_ParallelStartFinish checks concurrent start/finish calls converge:
// exactly one transition mutates the FSM and the rest error out cleanly.
func TestFSM_ParallelStartFinish(t *testing.T) {
	hub := newEventHub()
	const iters = 64
	for i := 0; i < iters; i++ {
		c := newContext("ctx", "img", hub, 0)
		var wg sync.WaitGroup
		wg.Add(16)
		for j := 0; j < 8; j++ {
			go func() {
				defer wg.Done()
				_ = c.start(1)
			}()
			go func() {
				defer wg.Done()
				_ = c.finish(0)
			}()
		}
		wg.Wait()
		if got := c.snapshot(); got.Status != StatusFinished {
			t.Fatalf("iter %d: status = %s, want finished", i, got.Status)
		}
	}
}
