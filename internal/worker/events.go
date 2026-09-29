package worker

import (
	"sync"
	"sync/atomic"
	"time"

	voilapb "voila/internal/proto"
)

// eventHub is the in-memory broadcast hub for context lifecycle events. It is
// OS-independent and untagged so its tests run on darwin.
//
// Subscriber model (plan §8 / task spec §8 events.go): each subscriber owns a
// *bounded* channel (eventChannelBufferSize). Publish does a non-blocking
// send; when the channel is full the event is *dropped* and a per-subscriber
// counter is incremented. The choice trades gap-free delivery for non-blocking
// publication — a slow or stalled subscriber (e.g. a Events client that stops
// reading) must never stall the daemon's FSM loop or block other, faster
// subscribers. Event payloads are tiny and the FSM emits a handful per
// context lifetime, so a 256-entry buffer is ample for any realistic
// subscriber; overflow is observable via Dropped().
//
// Events are never replayed on subscribe (plan §8: "clients subscribe, never
// poll"; subscribe does NOT replay past events — documented).
type eventHub struct {
	mu     sync.Mutex
	subs   map[int64]*eventSub
	nextID int64
}

// eventChannelBufferSize is per-subscriber. 256 comfortably holds an entire
// context's lifecycle (≤4 events) plus noise from many concurrent contexts.
const eventChannelBufferSize = 256

type eventSub struct {
	id      int64
	filter  string // context_id, "" = all
	ch      chan *voilapb.Event
	dropped atomic.Int64
}

func newEventHub() *eventHub {
	return &eventHub{subs: map[int64]*eventSub{}}
}

// subscribe registers a new subscriber. filter is a context_id; "" subscribes
// to every context's events. Returns the receive channel and a cancel
// function that unregisters the subscriber (idempotent; safe to call from any
// goroutine). The channel is buffered; an overflowed event is counted via
// the subscriber's dropped counter (see Dropped).
func (h *eventHub) subscribe(filter string) (<-chan *voilapb.Event, func()) {
	h.mu.Lock()
	h.nextID++
	s := &eventSub{
		id:     h.nextID,
		filter: filter,
		ch:     make(chan *voilapb.Event, eventChannelBufferSize),
	}
	h.subs[s.id] = s
	h.mu.Unlock()

	var once sync.Once
	cancel := func() {
		once.Do(func() {
			h.mu.Lock()
			delete(h.subs, s.id)
			h.mu.Unlock()
		})
	}
	return s.ch, cancel
}

// publish broadcasts ev to every subscriber whose filter matches. It is
// non-blocking: a full subscriber channel causes a counted drop. A nil ev is
// ignored.
func (h *eventHub) publish(ev *voilapb.Event) {
	if ev == nil {
		return
	}
	h.mu.Lock()
	// Snapshot subscribers under the lock so a publish from inside cancel
	// (called concurrently by a subscriber goroutine) cannot race us.
	for _, s := range h.subs {
		if s.filter != "" && s.filter != ev.GetContextId() {
			continue
		}
		select {
		case s.ch <- ev:
		default:
			s.dropped.Add(1)
		}
	}
	h.mu.Unlock()
}

// subscriberCount returns the current number of subscribers; used by tests.
func (h *eventHub) subscriberCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}

// newEvent constructs an Event with the given fields and a current timestamp.
func newEvent(ctxID string, typ voilapb.EventType, exitCode int32) *voilapb.Event {
	return &voilapb.Event{
		ContextId:   ctxID,
		Type:        typ,
		TimestampNs: time.Now().UnixNano(),
		ExitCode:    exitCode,
	}
}
