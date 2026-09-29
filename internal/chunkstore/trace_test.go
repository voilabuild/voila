package chunkstore

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// traceFakeStore is an in-memory ChunkStore whose Stat reflects actual
// presence (unlike the counting tests' fake), so TraceStore hit/miss
// classification can be exercised: present at Stat → "hit", absent → "miss".
type traceFakeStore struct {
	chunks map[ChunkID][]byte
}

func (s *traceFakeStore) Put(buf []byte) (ChunkID, error) { return ChunkID{}, nil }
func (s *traceFakeStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	b, ok := s.chunks[id]
	if !ok {
		return nil, ErrNotFound
	}
	return b, nil
}
func (s *traceFakeStore) Stat(id ChunkID) (ChunkMeta, bool) {
	_, ok := s.chunks[id]
	return ChunkMeta{}, ok
}
func (s *traceFakeStore) GC(reachable map[ChunkID]struct{}) (int, error) { return 0, nil }
func (s *traceFakeStore) Close() error                                   { return nil }

// readTraceEvents parses a trace file into raw JSON maps for field-level
// assertions without coupling the test to the event struct field order.
func readTraceEvents(t *testing.T, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var events []map[string]any
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		var m map[string]any
		if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
			t.Fatalf("invalid JSON line %q: %v", sc.Text(), err)
		}
		events = append(events, m)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return events
}

// TestTraceStore_HitMissClassification verifies a chunk present locally
// traces as "hit" (the Stat-before-Get rule), and that a failed Get is not
// recorded.
func TestTraceStore_HitMissClassification(t *testing.T) {
	inner := &traceFakeStore{chunks: map[ChunkID][]byte{
		{0x01}: []byte("aaaa"),
	}}
	path := filepath.Join(t.TempDir(), "trace.jsonl")
	tw, err := NewTraceWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	ts := NewTrace(inner, tw)

	if _, err := ts.Get(context.Background(), ChunkID{0x01}); err != nil {
		t.Fatal(err)
	}
	// Failed Gets are not recorded.
	if _, err := ts.Get(context.Background(), ChunkID{0x09}); err == nil {
		t.Fatal("expected ErrNotFound from empty store")
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}

	events := readTraceEvents(t, path)
	if len(events) != 1 {
		t.Fatalf("expected 1 event (failed Get not recorded), got %d", len(events))
	}
	ev := events[0]
	if ev["type"] != "get" || ev["result"] != "hit" {
		t.Fatalf("expected get/hit, got %v", ev)
	}
	if ev["bytes"].(float64) != 4 {
		t.Fatalf("expected bytes=4, got %v", ev["bytes"])
	}
	if ev["source"] != SourceDemand {
		t.Fatalf("expected default source %q, got %v", SourceDemand, ev["source"])
	}
}

// statAbsentStore wraps a store and forces Stat to report absent, simulating
// the local-miss half of a CachedStore (Get succeeds after remote fetch).
type statAbsentStore struct{ inner *traceFakeStore }

func (s *statAbsentStore) Put(buf []byte) (ChunkID, error) { return s.inner.Put(buf) }
func (s *statAbsentStore) Get(ctx context.Context, id ChunkID) ([]byte, error) {
	// Serve only what the inner store has, but pretend nothing is local.
	if id == (ChunkID{0x02}) {
		return []byte("remote-bytes"), nil
	}
	return s.inner.Get(ctx, id)
}
func (s *statAbsentStore) Stat(id ChunkID) (ChunkMeta, bool)              { return ChunkMeta{}, false }
func (s *statAbsentStore) GC(reachable map[ChunkID]struct{}) (int, error) { return 0, nil }
func (s *statAbsentStore) Close() error                                   { return nil }

// TestTraceStore_MissAndSource verifies miss classification and that a
// WithSource-tagged context lands in the event's source field + totals.
func TestTraceStore_MissAndSource(t *testing.T) {
	inner := &statAbsentStore{inner: &traceFakeStore{chunks: map[ChunkID][]byte{}}}
	path := filepath.Join(t.TempDir(), "trace.jsonl")
	tw, err := NewTraceWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	ts := NewTrace(inner, tw)

	if _, err := ts.Get(context.Background(), ChunkID{0x02}); err != nil {
		t.Fatal(err)
	}
	pctx := WithSource(context.Background(), SourcePrefetch)
	if _, err := ts.Get(pctx, ChunkID{0x02}); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}

	events := readTraceEvents(t, path)
	if len(events) != 2 {
		t.Fatalf("expected 2 events, got %d", len(events))
	}
	if events[0]["result"] != "miss" || events[0]["source"] != SourceDemand {
		t.Fatalf("expected miss/demand, got %v", events[0])
	}
	if events[1]["result"] != "miss" || events[1]["source"] != SourcePrefetch {
		t.Fatalf("expected miss/prefetch, got %v", events[1])
	}

	totals := ts.Totals()
	if totals.Gets != 2 || totals.Misses != 2 {
		t.Fatalf("expected gets=2 misses=2, got %+v", totals)
	}
	if totals.DemandWaitNS <= 0 || totals.PrefetchWaitNS <= 0 {
		t.Fatalf("expected positive wait totals, got %+v", totals)
	}
}

// TestTraceWriter_RoundTrip verifies the writer produces one valid JSON
// object per line and Close flushes.
func TestTraceWriter_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "trace.jsonl")
	tw, err := NewTraceWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	tw.Emit(RunStartEvent{Type: "run_start", TNS: tw.TNS(), Wall: "2026-08-22T10:00:00Z", Image: "ref", Backend: "fuse"})
	tw.Emit(PhaseEvent{Type: "phase", TNS: tw.TNS(), Name: "exec"})
	tw.Emit(RunEndEvent{Type: "run_end", TNS: tw.TNS(), Totals: RunEndTotals{Gets: 1}})
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil { // idempotent
		t.Fatal(err)
	}

	events := readTraceEvents(t, path)
	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d", len(events))
	}
	if events[0]["type"] != "run_start" || events[1]["name"] != "exec" || events[2]["type"] != "run_end" {
		t.Fatalf("unexpected events: %v", events)
	}
}
