package main

import (
	"testing"

	voilapb "voila/internal/proto"
)

// TestFormatFetchedLine verifies the rendering of the per-run fetch stats
// line under every shape of image totals: omitted (no parenthetical), only
// chunks, only bytes, both, and a nil / empty stats frame. Percentages use
// one decimal; bytes use the existing formatBytes helper (KiB/MiB/GiB).
func TestFormatFetchedLine(t *testing.T) {
	// 12.40 MiB = 12 * MiB + 0.40 * MiB; 12.40 MiB = 0x00C0_0000 + ...
	const MiB uint64 = 1 << 20
	const GiB uint64 = 1 << 30
	cases := []struct {
		name  string
		stats *voilapb.FetchStats
		want  string
	}{
		{
			name:  "nil stats returns empty",
			stats: nil,
			want:  "",
		},
		{
			name:  "zero everything no totals",
			stats: &voilapb.FetchStats{},
			want:  "fetched: 0 chunks / 0 B",
		},
		{
			name:  "no image totals omits parenthetical",
			stats: &voilapb.FetchStats{ChunksFetched: 143, BytesFetched: 12 * MiB},
			want:  "fetched: 143 chunks / 12.00 MiB",
		},
		{
			name: "only chunks total → chunks pct clause only",
			stats: &voilapb.FetchStats{
				ChunksFetched: 143,
				BytesFetched:  12 * MiB,
				ImageChunks:   26647,
			},
			want: "fetched: 143 chunks / 12.00 MiB (0.5% of 26647 chunks)",
		},
		{
			name: "only bytes total → bytes pct clause only",
			stats: &voilapb.FetchStats{
				ChunksFetched: 143,
				BytesFetched:  12 * MiB,
				ImageBytes:    GiB,
			},
			want: "fetched: 143 chunks / 12.00 MiB (1.2% of 1.00 GiB)",
		},
		{
			name: "both totals → both clauses comma-separated",
			stats: &voilapb.FetchStats{
				ChunksFetched: 143,
				BytesFetched:  12 * MiB,
				ImageChunks:   26647,
				ImageBytes:    GiB,
			},
			want: "fetched: 143 chunks / 12.00 MiB (0.5% of 26647 chunks, 1.2% of 1.00 GiB)",
		},
		{
			name: "percent rounding one decimal",
			stats: &voilapb.FetchStats{
				ChunksFetched: 1,
				BytesFetched:  0,
				ImageChunks:   3,
			},
			want: "fetched: 1 chunks / 0 B (33.3% of 3 chunks)",
		},
		{
			name: "large bytes renders with GiB unit",
			stats: &voilapb.FetchStats{
				ChunksFetched: 1500,
				BytesFetched:  2 * GiB,
				ImageChunks:   60000,
				ImageBytes:    8 * GiB,
			},
			want: "fetched: 1500 chunks / 2.00 GiB (2.5% of 60000 chunks, 25.0% of 8.00 GiB)",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := formatFetchedLine(c.stats)
			if got != c.want {
				t.Errorf("formatFetchedLine(%v) =\n  %q\nwant\n  %q", c.stats, got, c.want)
			}
		})
	}
}

// TestFormatFetchedColumn exercises the `voila ps` FETCHED column renderer:
// "-" when stats is nil, "<chunks>/<human bytes>" otherwise.
func TestFormatFetchedColumn(t *testing.T) {
	const MiB uint64 = 1 << 20
	cases := []struct {
		name string
		info *voilapb.ContextInfo
		want string
	}{
		{name: "nil stats dash", info: &voilapb.ContextInfo{}, want: "-"},
		{name: "zero stats renders 0/0 B",
			info: &voilapb.ContextInfo{Stats: &voilapb.FetchStats{}},
			want: "0/0 B"},
		{name: "nonzero stats",
			info: &voilapb.ContextInfo{Stats: &voilapb.FetchStats{
				ChunksFetched: 143, BytesFetched: 12 * MiB,
			}},
			want: "143/12.00 MiB"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := formatFetched(c.info); got != c.want {
				t.Errorf("formatFetched = %q, want %q", got, c.want)
			}
		})
	}
}
