package runtime

import (
	"encoding/json"
	"testing"
)

// mustJSON encodes v and panics on failure — helper for test fixtures.
func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestParseImageConfig_Fields verifies the OCI image config round-trips into
// ImageConfig with all four process-default fields preserved.
func TestParseImageConfig_Fields(t *testing.T) {
	raw := mustJSON(t, map[string]any{
		"architecture": "amd64",
		"os":           "linux",
		"config": map[string]any{
			"Env":        []string{"FOO=bar", "BAZ=qux"},
			"Entrypoint": []string{"/bin/sh", "-c"},
			"Cmd":        []string{"echo hi"},
			"WorkingDir": "/srv",
		},
		"rootfs":  map[string]any{"type": "layers", "digests": []string{}},
		"history": []any{},
	})
	cfg, err := ParseImageConfig(raw)
	if err != nil {
		t.Fatalf("ParseImageConfig: %v", err)
	}
	if len(cfg.Env) != 2 || cfg.Env[0] != "FOO=bar" {
		t.Errorf("Env = %v, want [FOO=bar BAZ=qux]", cfg.Env)
	}
	if len(cfg.Entrypoint) != 2 || cfg.Entrypoint[0] != "/bin/sh" {
		t.Errorf("Entrypoint = %v, want [/bin/sh -c]", cfg.Entrypoint)
	}
	if len(cfg.Cmd) != 1 || cfg.Cmd[0] != "echo hi" {
		t.Errorf("Cmd = %v, want [echo hi]", cfg.Cmd)
	}
	if cfg.WorkingDir != "/srv" {
		t.Errorf("WorkingDir = %q, want /srv", cfg.WorkingDir)
	}
}

// TestParseImageConfig_Empty rejects empty input.
func TestParseImageConfig_Empty(t *testing.T) {
	if _, err := ParseImageConfig(nil); err == nil {
		t.Fatal("expected error for nil input")
	}
	if _, err := ParseImageConfig([]byte{}); err == nil {
		t.Fatal("expected error for empty input")
	}
}

// TestArgv_MergeMatrix exercises the docker-style merge for entrypoint + cmd
// + command-line override combinations.
func TestArgv_MergeMatrix(t *testing.T) {
	cases := []struct {
		name       string
		entrypoint []string
		cmd        []string
		override   []string
		want       []string
	}{
		{
			name:       "entrypoint+cmd",
			entrypoint: []string{"/bin/sh", "-c"},
			cmd:        []string{"echo hi"},
			override:   nil,
			want:       []string{"/bin/sh", "-c", "echo hi"},
		},
		{
			name:       "entrypoint+override",
			entrypoint: []string{"/bin/sh", "-c"},
			cmd:        []string{"echo bye"},
			override:   []string{"echo hi"},
			want:       []string{"/bin/sh", "-c", "echo hi"},
		},
		{
			name:       "no entrypoint cmd only",
			entrypoint: nil,
			cmd:        []string{"bash"},
			override:   nil,
			want:       []string{"bash"},
		},
		{
			name:       "no entrypoint override",
			entrypoint: nil,
			cmd:        []string{"bash"},
			override:   []string{"python"},
			want:       []string{"python"},
		},
		{
			name:       "both empty",
			entrypoint: nil,
			cmd:        nil,
			override:   nil,
			want:       []string{},
		},
		{
			name:       "override empty no cmd",
			entrypoint: []string{"tini"},
			cmd:        nil,
			override:   nil,
			want:       []string{"tini"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &ImageConfig{Entrypoint: tc.entrypoint, Cmd: tc.cmd}
			got := c.Argv(tc.override)
			if !equalStrings(got, tc.want) {
				t.Errorf("Argv(%v) = %v, want %v", tc.override, got, tc.want)
			}
		})
	}
}

// TestEnviron_PathInjection covers PATH default injection.
func TestEnviron_PathInjection(t *testing.T) {
	// Absent → injected.
	c := &ImageConfig{Env: []string{"FOO=bar"}}
	got := c.Environ()
	if len(got) != 2 {
		t.Fatalf("Env len = %d, want 2", len(got))
	}
	if got[1] != defaultPath {
		t.Errorf("injected PATH = %q, want %q", got[1], defaultPath)
	}
	// Present → untouched.
	c2 := &ImageConfig{Env: []string{"PATH=/custom", "FOO=bar"}}
	got2 := c2.Environ()
	if len(got2) != 2 {
		t.Fatalf("untouched Env len = %d, want 2", len(got2))
	}
	if got2[0] != "PATH=/custom" {
		t.Errorf("PATH overwritten = %q, want /custom", got2[0])
	}
}

// TestCwd_Default verifies Cwd returns "/" when WorkingDir is empty.
func TestCwd_Default(t *testing.T) {
	c := &ImageConfig{}
	if got := c.Cwd(); got != "/" {
		t.Errorf("Cwd() = %q, want /", got)
	}
	c2 := &ImageConfig{WorkingDir: "/srv"}
	if got := c2.Cwd(); got != "/srv" {
		t.Errorf("Cwd() = %q, want /srv", got)
	}
}

// equalStrings reports slice equality. nil and empty are treated as equal so
// Argv's contract (returning a non-nil empty slice when both are empty) is
// tested fairly.
func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
