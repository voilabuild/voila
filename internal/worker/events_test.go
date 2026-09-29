package worker

import (
	"sync"
	"testing"
	"time"

	voilapb "voila/internal/proto"
)

// TestEvents_TwoSubscribers verifies that two subscribers both receive every
// event published while they are subscribed.
func TestEvents_TwoSubscribers(t *testing.T) {
	hub := newEventHub()
	aCh, cancelA := hub.subscribe("")
	bCh, cancelB := hub.subscribe("")
	defer cancelA()
	defer cancelB()

	for i := 0; i < 5; i++ {
		hub.publish(&voilapb.Event{ContextId: "c", Type: voilapb.EventType_EVENT_TYPE_SCHEDULED, TimestampNs: int64(i)})
	}
	if got := drainN(t, aCh, 5); got != 5 {
		t.Fatalf("a saw %d, want 5", got)
	}
	cancelA() // exercise unsubscribe while b is still live

	if got := drainN(t, bCh, 5); got != 5 {
		t.Fatalf("b saw %d, want 5 (cancel of a must not affect b)", got)
	}
}

// TestEvents_Filter verifies the context_id filter only delivers matching events.
func TestEvents_Filter(t *testing.T) {
	hub := newEventHub()
	ch, cancel := hub.subscribe("ctx-1")
	defer cancel()
	hub.publish(&voilapb.Event{ContextId: "ctx-2", Type: voilapb.EventType_EVENT_TYPE_SCHEDULED})
	hub.publish(&voilapb.Event{ContextId: "ctx-1", Type: voilapb.EventType_EVENT_TYPE_STARTED})
	hub.publish(&voilapb.Event{ContextId: "ctx-1", Type: voilapb.EventType_EVENT_TYPE_FINISHED, ExitCode: 2})

	if got := drainN(t, ch, 2); got != 2 {
		t.Fatalf("filtered sub got %d, want 2 (1 ctx excluded)", got)
	}
}

// TestEvents_SlowSubscriberDoesNotBlock verifies the publisher never blocks
// when a subscriber stops reading — bounded buffer + drop-with-counter.
func TestEvents_SlowSubscriberDoesNotBlock(t *testing.T) {
	hub := newEventHub()
	_, cancelSlow := hub.subscribe("")
	defer cancelSlow()
	// Drain nothing on purpose.
	// Publish many more events than the buffer holds.
	const n = eventChannelBufferSize * 10
	start := time.Now()
	for i := 0; i < n; i++ {
		hub.publish(&voilapb.Event{ContextId: "c"})
	}
	elapsed := time.Since(start)
	// Generous budget: gRPC SendMsg / channel ops are fast; capping at a
	// tight deadline catches "publisher blocking on receiver".
	if elapsed > 2*time.Second {
		t.Fatalf("publish blocked: %v", elapsed)
	}
	cancelSlow()
}

// TestEvents_NoReplay verifies that subscribe does NOT replay past events
// (plan §8: clients subscribe, never poll; documented).
func TestEvents_NoReplay(t *testing.T) {
	hub := newEventHub()
	hub.publish(&voilapb.Event{ContextId: "before-subscribe"})

	ch, cancel := hub.subscribe("")
	defer cancel()
	// Give publish-on-subscribe a moment; expect NOTHING for the pre-subscribe
	// event, then publish one and expect exactly that one.
	select {
	case <-ch:
		t.Fatal("received a pre-subscribe event (replay) — must not replay")
	case <-time.After(20 * time.Millisecond):
	}
	hub.publish(&voilapb.Event{ContextId: "after-subscribe"})
	if got := drainN(t, ch, 1); got != 1 {
		t.Fatalf("got %d, want 1 post-subscribe event", got)
	}
}

// TestEvents_ConcurrentPublish exercises the publish path under concurrent
// publishers; mostly a race detector shakedown.
func TestEvents_ConcurrentPublish(t *testing.T) {
	hub := newEventHub()
	ch, cancel := hub.subscribe("")
	defer cancel()
	var wg sync.WaitGroup
	for p := 0; p < 4; p++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				hub.publish(&voilapb.Event{ContextId: "c"})
			}
		}(p)
	}
	wg.Wait()
	// Drain so the buffer doesn't keep blocked subs alive past the test.
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

// drainN reads up to n events from ch within a deadline and returns the count
// actually received.
func drainN(t *testing.T, ch <-chan *voilapb.Event, n int) int {
	t.Helper()
	got := 0
	deadline := time.After(2 * time.Second)
	for got < n {
		select {
		case _, ok := <-ch:
			if !ok {
				return got
			}
			got++
		case <-deadline:
			return got
		}
	}
	return got
}
