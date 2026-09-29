// Package progress is a tiny live progress reporter for long-running CLI
// operations (currently `voila push`). It supports two modes:
//
//   - TTY mode (the default when the writer is a terminal): a single line is
//     refreshed in place with \r, showing phase, bytes uploaded, chunk count,
//     rate, and ETA. The line is cleared on Stop so the caller's final
//     summary line lands on a fresh line.
//   - non-TTY mode (piped to a file / CI log): a compact summary line is
//     printed every few seconds so logs are not spammed but progress is still
//     visible.
//
// It is stdlib-only (TTY detection uses os.File.Stat, not golang.org/x/term)
// and safe for concurrent use: workers call Add concurrently while a single
// ticker goroutine renders.
package progress

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// renderInterval is the minimum cadence between TTY redraws / non-TTY summary
// lines. 200ms is fast enough to feel live without burning CPU on a tight
// render loop; non-TTY uses a longer effective interval (see logInterval).
const renderInterval = 200 * time.Millisecond

// logInterval is the cadence in non-TTY mode. CI logs do not want 5 lines per
// second; one line every 5s is enough to see a long push is making progress.
const logInterval = 5 * time.Second

// barWidth is the number of runes in the ASCII progress bar.
const barWidth = 24

// Reporter is a live progress reporter. Call Add from workers as work
// completes; SetPhase to change the leading label; Stop to finalize.
type Reporter struct {
	w    io.Writer
	tty  bool
	stop chan struct{}

	// Total work — set at construction so the bar + ETA can be computed.
	totalChunks int
	totalBytes  uint64

	// Atomic counters updated by workers. int64 for atomic ops; the bytes
	// counter is uint64 in the public API but stored as int64 here (a push
	// never transfers more than 2^63 bytes).
	uploaded atomic.Int64
	bytes    atomic.Int64
	already  atomic.Int64

	mu       sync.Mutex
	phase    string
	start    time.Time
	lastDraw time.Time
	stopped  bool
}

// New returns a Reporter that writes to w. totalChunks and totalBytes are the
// full size of the work (e.g. the missing-chunk set + the sum of their logical
// sizes); the bar fills against these. If w is not a terminal, the reporter
// switches to the low-frequency log-line mode automatically.
func New(w io.Writer, totalChunks int, totalBytes uint64) *Reporter {
	tty := false
	if f, ok := w.(*os.File); ok {
		if fi, err := f.Stat(); err == nil {
			tty = fi.Mode()&os.ModeCharDevice != 0
		}
	}
	return &Reporter{
		w:           w,
		tty:         tty,
		stop:        make(chan struct{}),
		totalChunks: totalChunks,
		totalBytes:  totalBytes,
		start:       time.Now(),
	}
}

// Start launches the renderer goroutine. The phase label is shown before the
// bar. Returns the Reporter itself so callers can chain.
func (r *Reporter) Start(phase string) *Reporter {
	r.mu.Lock()
	r.phase = phase
	r.mu.Unlock()
	go r.loop()
	return r
}

// SetPhase updates the leading phase label (e.g. "negotiating" → "uploading").
func (r *Reporter) SetPhase(phase string) {
	r.mu.Lock()
	r.phase = phase
	// Force a redraw on the next tick by resetting lastDraw to zero.
	r.lastDraw = time.Time{}
	r.mu.Unlock()
}

// Add records n completed chunks and b logical bytes uploaded. Safe to call
// from many goroutines.
func (r *Reporter) Add(n int, b uint64) {
	r.uploaded.Add(int64(n))
	r.bytes.Add(int64(b))
}

// SetTotal updates the total work the bar fills against. Useful when the
// total is not known until a negotiation phase completes (e.g. push only
// learns the missing-chunk set after POST /v1/chunks/missing); the reporter
// can be Started immediately with a 0/0 total and updated once the real total
// is known. Safe to call from a different goroutine than the renderer.
func (r *Reporter) SetTotal(totalChunks int, totalBytes uint64) {
	r.mu.Lock()
	r.totalChunks = totalChunks
	r.totalBytes = totalBytes
	r.lastDraw = time.Time{} // force a redraw
	r.mu.Unlock()
}

// Stop finalizes the report. In TTY mode it clears the live line so the
// caller's own final summary line lands cleanly; in non-TTY mode it prints a
// final summary line. It is safe to call multiple times.
func (r *Reporter) Stop() {
	r.mu.Lock()
	if r.stopped {
		r.mu.Unlock()
		return
	}
	r.stopped = true
	r.mu.Unlock()
	close(r.stop)
	if r.tty {
		// Clear the line and move to the start so the caller's next print
		// (the "pushed <ref>: ..." summary) is on a fresh line.
		fmt.Fprint(r.w, "\r"+strings.Repeat(" ", 80)+"\r")
	} else {
		r.render(true)
	}
}

// loop is the renderer goroutine: ticks at renderInterval and redraws (TTY)
// or logs at logInterval (non-TTY). Exits when Stop closes r.stop.
func (r *Reporter) loop() {
	ticker := time.NewTicker(renderInterval)
	defer ticker.Stop()
	for {
		select {
		case <-r.stop:
			return
		case <-ticker.C:
			r.render(false)
		}
	}
}

// render writes one progress line. final is true on the Stop call (non-TTY
// only) so a last summary is emitted even if the log interval had not elapsed.
func (r *Reporter) render(final bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()
	if !final && !r.lastDraw.IsZero() {
		if r.tty {
			if now.Sub(r.lastDraw) < renderInterval {
				return
			}
		} else if now.Sub(r.lastDraw) < logInterval {
			return
		}
	}
	r.lastDraw = now

	uploaded := r.uploaded.Load()
	bytes := r.bytes.Load()
	elapsed := now.Sub(r.start).Seconds()
	if elapsed < 0 {
		elapsed = 0
	}
	rate := 0.0
	if elapsed > 0 {
		rate = float64(bytes) / elapsed
	}

	if r.tty {
		r.drawTTY(uploaded, bytes, elapsed, rate)
	} else {
		r.drawLog(uploaded, bytes, elapsed, rate, final)
	}
}

// drawTTY writes the single in-place TTY line: phase + bar + counts + rate + ETA.
func (r *Reporter) drawTTY(uploaded, bytes int64, elapsed, rate float64) {
	var bar strings.Builder
	bar.WriteByte('[')
	filled := 0
	if r.totalChunks > 0 {
		filled = int(int64(barWidth) * uploaded / int64(r.totalChunks))
	}
	if filled > barWidth {
		filled = barWidth
	}
	for i := 0; i < barWidth; i++ {
		if i < filled {
			bar.WriteByte('=')
		} else if i == filled {
			bar.WriteByte('>')
		} else {
			bar.WriteByte(' ')
		}
	}
	bar.WriteByte(']')

	eta := "—"
	if rate > 0 && r.totalBytes > 0 {
		remaining := int64(r.totalBytes) - bytes
		if remaining <= 0 {
			eta = "done"
		} else {
			secs := int(float64(remaining) / rate)
			eta = formatDuration(secs)
		}
	}

	// r.mu is held by the caller (render); read phase without re-locking.
	phase := r.phase

	fmt.Fprintf(r.w, "\r%s %s %d/%d chunks  %s/%s  %s/s  ETA %s   ",
		phase,
		bar.String(),
		uploaded, r.totalChunks,
		formatBytes(uint64(bytes)), formatBytes(r.totalBytes),
		formatBytes(uint64(rate)),
		eta)
}

// drawLog writes a compact non-TTY summary line. final adds an "upload done"
// marker so the last line is distinguishable in a log. r.mu is held by the
// caller (render); read phase without re-locking.
func (r *Reporter) drawLog(uploaded, bytes int64, elapsed, rate float64, final bool) {
	phase := r.phase
	marker := "..."
	if final {
		marker = "done"
	}
	fmt.Fprintf(r.w, "%s %s: %d/%d chunks, %s/%s, %s/s, elapsed %s\n",
		marker, phase,
		uploaded, r.totalChunks,
		formatBytes(uint64(bytes)), formatBytes(r.totalBytes),
		formatBytes(uint64(rate)),
		formatDuration(int(elapsed)))
}

// formatBytes renders a byte count with 2-decimal binary units. It mirrors
// cli.FormatBytes so the progress line and the final summary line agree; the
// helper is duplicated here to keep this package free of the cli package's
// heavier imports (grpc / proto).
func formatBytes(n uint64) string {
	const (
		KiB = 1 << 10
		MiB = 1 << 20
		GiB = 1 << 30
		TiB = 1 << 40
	)
	switch {
	case n >= TiB:
		return fmt.Sprintf("%.2f TiB", float64(n)/float64(TiB))
	case n >= GiB:
		return fmt.Sprintf("%.2f GiB", float64(n)/float64(GiB))
	case n >= MiB:
		return fmt.Sprintf("%.2f MiB", float64(n)/float64(MiB))
	case n >= KiB:
		return fmt.Sprintf("%.2f KiB", float64(n)/float64(KiB))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// formatDuration renders a duration in seconds as a compact h/m/s string for
// ETA display.
func formatDuration(secs int) string {
	if secs < 0 {
		secs = 0
	}
	if secs < 60 {
		return fmt.Sprintf("%ds", secs)
	}
	if secs < 3600 {
		return fmt.Sprintf("%dm%ds", secs/60, secs%60)
	}
	return fmt.Sprintf("%dh%dm", secs/3600, (secs%3600)/60)
}
