package cli

import (
	"errors"
	"strings"
	"testing"
)

func TestReorderArgs(t *testing.T) {
	tests := []struct {
		name string
		in   []string
		want []string
	}{
		{name: "empty", in: []string{}, want: []string{}},
		{
			name: "flags already first",
			in:   []string{"-root", "/tmp", "ref"},
			want: []string{"-root", "/tmp", "ref"},
		},
		{
			name: "trailing flags move front",
			in:   []string{"ref", "-registry", "https://x", "-root", "/tmp"},
			want: []string{"-registry", "https://x", "-root", "/tmp", "ref"},
		},
		{
			name: "relative order preserved within groups",
			in:   []string{"pos1", "-a", "pos2", "-b", "3"},
			// "-a" claims "pos2" and "-b" claims "3" as their values (the
			// value heuristic cannot tell boolean flags apart from
			// value-taking ones); both pairs stay in order.
			want: []string{"-a", "pos2", "-b", "3", "pos1"},
		},
		{
			name: "terminator freezes the tail",
			in:   []string{"img", "--", "python", "-c", "print(1)"},
			want: []string{"img", "--", "python", "-c", "print(1)"},
		},
		{
			name: "flags before terminator still reorder",
			in:   []string{"img", "-memory", "100m", "--", "echo", "-n", "hi"},
			want: []string{"-memory", "100m", "img", "--", "echo", "-n", "hi"},
		},
		{
			name: "bare dash stays positional",
			in:   []string{"-", "-x", "pos"},
			// "-x" claims "pos" as its value per the pairing heuristic.
			want: []string{"-x", "pos", "-"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ReorderArgs(tc.in)
			if strings.Join(got, "\x00") != strings.Join(tc.want, "\x00") {
				t.Fatalf("ReorderArgs(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestExecute_ReorderedArgsReachRun verifies the tree applies ReorderArgs at
// Run dispatch, so a leaf sees trailing flags first — the property that lets
// stdlib flag accept documented synopsis forms.
func TestExecute_ReorderedArgsReachRun(t *testing.T) {
	var got []string
	root := &Command{
		Name: "prog",
		Run: func(args []string) error {
			got = args
			return errors.New("ran")
		},
	}
	if err := root.Execute(&strings.Builder{}, []string{"ref", "-registry", "u"}); err == nil {
		t.Fatal("expected Run error")
	}
	if strings.Join(got, "\x00") != "-registry\x00u\x00ref" {
		t.Fatalf("Run args = %q, want flags moved before positionals", got)
	}
}

// TestExecute_TerminatorNotReordered verifies `--` and its tail reach Run
// verbatim even when voila-level flags trail the positional.
func TestExecute_TerminatorNotReordered(t *testing.T) {
	var got []string
	root := &Command{
		Name: "prog",
		Run: func(args []string) error {
			got = args
			return errors.New("ran")
		},
	}
	if err := root.Execute(&strings.Builder{}, []string{"img", "-root", "/r", "--", "echo", "-n", "x"}); err == nil {
		t.Fatal("expected Run error")
	}
	want := "-root\x00/r\x00img\x00--\x00echo\x00-n\x00x"
	if strings.Join(got, "\x00") != want {
		t.Fatalf("Run args = %q, want %q", got, want)
	}
}
