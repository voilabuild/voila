package cli

import "testing"

func TestFormatBytes(t *testing.T) {
	cases := []struct {
		n    uint64
		want string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1 << 10, "1.00 KiB"},
		{1 << 20, "1.00 MiB"},
		{1 << 30, "1.00 GiB"},
		{1 << 40, "1.00 TiB"},
		{(1 << 20) + (1 << 19), "1.50 MiB"},
	}
	for _, c := range cases {
		if got := FormatBytes(c.n); got != c.want {
			t.Errorf("FormatBytes(%d) = %q, want %q", c.n, got, c.want)
		}
	}
}

func TestShortDigest(t *testing.T) {
	if ShortDigest(nil) != "-" {
		t.Error("nil digest should render as -")
	}
	d := []byte{0xab, 0xcd, 0xef, 0x01, 0x23, 0x45}
	if got := ShortDigest(d); got != "abcdef012345" {
		t.Errorf("ShortDigest = %q, want %q", got, "abcdef012345")
	}
}

// TestShortDigest_TruncatesLongDigest to ShortDigest's 12-char cap: a 32-byte
// (256-bit) digest renders its leading 12 hex chars only.
func TestShortDigest_TruncatesLongDigest(t *testing.T) {
	d := make([]byte, 32)
	for i := range d {
		d[i] = byte(i)
	}
	got := ShortDigest(d)
	if len(got) != 12 {
		t.Errorf("ShortDigest len = %d, want 12 (got %q)", len(got), got)
	}
}

func TestFormatTime(t *testing.T) {
	if got := FormatTime(0); got != "-" {
		t.Errorf("FormatTime(0) = %q, want -", got)
	}
	if got := FormatTime(-1); got != "-" {
		t.Errorf("FormatTime(-1) = %q, want -", got)
	}
	// A known instant: 2024-01-01T00:00:00Z = 1704067200 s.
	const ns = 1_704_067_200_000_000_000
	if got := FormatTime(ns); got != "2024-01-01T00:00:00Z" {
		t.Errorf("FormatTime(%d) = %q, want 2024-01-01T00:00:00Z", ns, got)
	}
}

func TestResolveRootPrecedence(t *testing.T) {
	t.Setenv("VOILA_ROOT", "/env/root")
	// 1. explicit wins.
	if got := ResolveRoot("/explicit", "/fallback"); got != "/explicit" {
		t.Errorf("explicit: got %q want /explicit", got)
	}
	// 2. fallback beats env.
	if got := ResolveRoot("", "/fallback"); got != "/fallback" {
		t.Errorf("fallback: got %q want /fallback", got)
	}
	// 3. env beats the default.
	if got := ResolveRoot("", ""); got != "/env/root" {
		t.Errorf("env: got %q want /env/root", got)
	}
	// 4. DefaultRoot (/var/lib/voila) when nothing is set.
	t.Setenv("VOILA_ROOT", "")
	if got := ResolveRoot("", ""); got != DefaultRoot {
		t.Errorf("default: got %q want %q", got, DefaultRoot)
	}
}

func TestResolveSocketPrecedence(t *testing.T) {
	t.Setenv("VOILA_SOCKET", "/env/socket")
	// 1. explicit wins.
	if got := ResolveSocket("/explicit", "", false, "/r"); got != "/explicit" {
		t.Errorf("explicit: got %q want /explicit", got)
	}
	// 2. fallback beats env.
	if got := ResolveSocket("", "/fallback", false, "/r"); got != "/fallback" {
		t.Errorf("fallback: got %q want /fallback", got)
	}
	// 3. env beats the root-pinned + default paths.
	if got := ResolveSocket("", "", true, "/r"); got != "/env/socket" {
		t.Errorf("env: got %q want /env/socket", got)
	}
	// 4. an explicit root pins the socket under it (back-compat).
	t.Setenv("VOILA_SOCKET", "")
	if got := ResolveSocket("", "", true, "/r"); got != "/r/worker.sock" {
		t.Errorf("root-pinned: got %q want /r/worker.sock", got)
	}
	// 5. otherwise the decoupled default /var/run/voila.sock.
	if got := ResolveSocket("", "", false, "/var/lib/voila"); got != DefaultSocket {
		t.Errorf("default: got %q want %q", got, DefaultSocket)
	}
}

func TestSocketPath(t *testing.T) {
	if got := SocketPath("/r"); got != "/r/worker.sock" {
		t.Errorf("SocketPath = %q, want /r/worker.sock", got)
	}
}
