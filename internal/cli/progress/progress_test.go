package progress

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// TestReporter_NonTTYEmitsFinalSummary verifies a non-TTY reporter (writing
// to a *bytes.Buffer, which is not a char device) emits at least one summary
// line on Stop, and that the line carries the phase + counts.
func TestReporter_NonTTYEmitsFinalSummary(t *testing.T) {
	var buf bytes.Buffer
	r := New(&buf, 10, 1<<20).Start("uploading")
	r.Add(3, 300<<10)
	r.Stop()
	out := buf.String()
	if !strings.Contains(out, "uploading") {
		t.Errorf("final line missing phase %q: %q", "uploading", out)
	}
	if !strings.Contains(out, "3/10 chunks") {
		t.Errorf("final line missing chunk count: %q", out)
	}
	if !strings.Contains(out, "done") {
		t.Errorf("final line missing 'done' marker: %q", out)
	}
}

// TestReporter_SetTotalUpdatesBar verifies SetTotal changes the denominator
// the bar fills against: after SetTotal(100, ...) and Add(50, ...), the
// reported chunk count is 50/100.
func TestReporter_SetTotalUpdatesBar(t *testing.T) {
	var buf bytes.Buffer
	r := New(&buf, 0, 0).Start("uploading")
	r.SetTotal(100, 1<<30)
	r.Add(50, 500<<20)
	r.Stop()
	out := buf.String()
	if !strings.Contains(out, "50/100 chunks") {
		t.Errorf("expected 50/100 chunks after SetTotal+Add: %q", out)
	}
}

// TestReporter_StopIdempotent verifies Stop can be called twice without
// panicking or emitting two final lines.
func TestReporter_StopIdempotent(t *testing.T) {
	var buf bytes.Buffer
	r := New(&buf, 10, 1<<20).Start("uploading")
	r.Stop()
	r.Stop()
	// Non-TTY emits exactly one "done" line on the first Stop; the second
	// Stop must not append another.
	if got := strings.Count(buf.String(), "done"); got != 1 {
		t.Errorf("Stop idempotency: saw %d 'done' lines, want 1: %q", got, buf.String())
	}
}

// TestReporter_AddAccumulatesConcurrently hammers Add from many goroutines to
// confirm the atomic counters are race-free (the -race runner would flag a
// partial read/write here). We only assert the final sum is exact.
func TestReporter_AddAccumulatesConcurrently(t *testing.T) {
	var buf bytes.Buffer
	r := New(&buf, 1000, 1<<24).Start("uploading")
	done := make(chan struct{})
	for i := 0; i < 8; i++ {
		go func() {
			for j := 0; j < 100; j++ {
				r.Add(1, 1<<10)
			}
			done <- struct{}{}
		}()
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	r.Stop()
	if got := r.uploaded.Load(); got != 800 {
		t.Errorf("uploaded = %d, want 800", got)
	}
}

// TestFormatBytes covers the unit ladder so the progress line and the final
// summary line (cli.FormatBytes) agree on magnitudes.
func TestFormatBytes(t *testing.T) {
	cases := []struct {
		n    uint64
		want string
	}{
		{0, "0 B"},
		{1023, "1023 B"},
		{1 << 10, "1.00 KiB"},
		{1 << 20, "1.00 MiB"},
		{1 << 30, "1.00 GiB"},
	}
	for _, c := range cases {
		if got := formatBytes(c.n); got != c.want {
			t.Errorf("formatBytes(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

// TestFormatDuration covers the ETA formatter's three regimes (seconds,
// minutes, hours).
func TestFormatDuration(t *testing.T) {
	cases := []struct {
		secs int
		want string
	}{
		{0, "0s"},
		{42, "42s"},
		{125, "2m5s"},
		{3700, "1h1m"},
	}
	for _, c := range cases {
		if got := formatDuration(c.secs); got != c.want {
			t.Errorf("formatDuration(%d) = %q, want %q", c.secs, got, c.want)
		}
	}
}

// keep the time import used (the package uses time elsewhere; this guard keeps
// a future trim from breaking the build if the other uses are refactored out).
var _ = time.Second
