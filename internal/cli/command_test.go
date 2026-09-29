package cli

import (
	"errors"
	"strings"
	"testing"
)

// testTree builds a small tree mirroring voila's shape: a root with flat
// commands plus one nested group (images-like) whose bare form has its own
// Run.
func testTree() *Command {
	return &Command{
		Name:   "prog",
		Footer: "footer line",
		Subs: []*Command{
			{
				Name:  "greet",
				Usage: "[-loud]",
				Short: "say hello",
				Run: func(args []string) error {
					if len(args) != 0 {
						return errors.New("greet got: " + strings.Join(args, " "))
					}
					return nil
				},
			},
			{
				Name:  "items",
				Usage: "[list | show <id>]",
				Short: "manage items",
				Run: func(args []string) error {
					if len(args) == 0 {
						return nil // bare form
					}
					return errors.New("items got: " + strings.Join(args, " "))
				},
				Subs: []*Command{
					{
						Name: "show", Usage: "<id>", Short: "show one item",
						Run: func(args []string) error { return errors.New("show ran") },
					},
				},
			},
			{Name: "passive", Short: "grouping only"}, // no Run, no Subs
		},
	}
}

func TestExecute_RoutesToRun(t *testing.T) {
	if err := testTree().Execute(&strings.Builder{}, []string{"greet"}); err != nil {
		t.Fatalf("Execute(greet): %v", err)
	}
}

func TestExecute_PassesRemainderToRun(t *testing.T) {
	err := testTree().Execute(&strings.Builder{}, []string{"greet", "-loud", "x"})
	if err == nil || !strings.Contains(err.Error(), "greet got: -loud x") {
		t.Fatalf("Execute should hand the full remainder to Run, got %v", err)
	}
}

func TestExecute_NestedSub(t *testing.T) {
	w := &strings.Builder{}
	err := testTree().Execute(w, []string{"items", "show", "42"})
	// items has a Run AND Subs; argv[0] "show" matches the child, so the
	// child wins and receives the post-word remainder.
	if err == nil || err.Error() != "show ran" {
		t.Fatalf("nested routing failed: %v", err)
	}
}

func TestExecute_BareGroupWithRun(t *testing.T) {
	// `items` with no args falls to its own Run (the list path).
	if err := testTree().Execute(&strings.Builder{}, []string{"items"}); err != nil {
		t.Fatalf("bare items: %v", err)
	}
}

func TestExecute_BareRootPrintsHelpAndErrUsage(t *testing.T) {
	var w strings.Builder
	err := testTree().Execute(&w, nil)
	if !errors.Is(err, ErrUsage) {
		t.Fatalf("err = %v, want ErrUsage", err)
	}
	for _, want := range []string{"usage: prog", "greet", "items", "footer line"} {
		if !strings.Contains(w.String(), want) {
			t.Errorf("help output missing %q:\n%s", want, w.String())
		}
	}
}

func TestExecute_UnknownCommandSuggests(t *testing.T) {
	var w strings.Builder
	err := testTree().Execute(&w, []string{"greets"})
	if !errors.Is(err, ErrUnknownCommand) {
		t.Fatalf("err = %v, want ErrUnknownCommand", err)
	}
	out := w.String()
	if !strings.Contains(out, `unknown command "greets"`) {
		t.Errorf("missing unknown-command message:\n%s", out)
	}
	if !strings.Contains(out, "Did you mean:") || !strings.Contains(out, "greet") {
		t.Errorf("missing did-you-mean suggestion:\n%s", out)
	}
}

func TestExecute_UnknownUnderGroupingNode(t *testing.T) {
	var w strings.Builder
	err := testTree().Execute(&w, []string{"passive", "anything"})
	if !errors.Is(err, ErrUnknownCommand) {
		t.Fatalf("err = %v, want ErrUnknownCommand", err)
	}
}

func TestFind_WalksAndStops(t *testing.T) {
	root := testTree()
	if node := root.Find([]string{"items", "show"}); node == nil || node.Name != "show" {
		t.Fatalf("Find(items show) = %v, want show", node)
	}
	if node := root.Find([]string{"items", "nope"}); node != nil {
		t.Fatalf("Find(items nope) = %v, want nil", node)
	}
	if node := root.Find(nil); node != root {
		t.Fatal("Find(nil) should return the root")
	}
}

func TestSimilar_EditDistanceAndPrefix(t *testing.T) {
	names := []string{"ingest", "images", "import", "ps"}
	// Prefix matches surface both images and import (short targets can also
	// pull in distance-2 strays like "ps"; suggestions are best-effort).
	got := Similar(names, "im", 2)
	if len(got) < 2 || got[0] != "images" || got[1] != "import" {
		t.Fatalf("Similar(im) = %v, want images+import first", got)
	}
	// One typo away from images.
	if got := Similar(names, "imagse", 2); len(got) != 1 || got[0] != "images" {
		t.Fatalf("Similar(imagse) = %v, want [images]", got)
	}
	// Exact match sorts first even alongside closer-prefix hits.
	if got := Similar(names, "ingest", 2); len(got) == 0 || got[0] != "ingest" {
		t.Fatalf("Similar(ingest) = %v, want ingest first", got)
	}
	if got := Similar(names, "zzzzzz", 2); len(got) != 0 {
		t.Fatalf("Similar(zzzzzz) = %v, want none", got)
	}
}

func TestLevenshtein(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"", "", 0}, {"a", "", 1}, {"", "abc", 3},
		{"kitten", "sitting", 3}, {"greet", "greets", 1},
		{"abc", "abc", 0},
	}
	for _, c := range cases {
		if got := levenshtein(c.a, c.b); got != c.want {
			t.Errorf("levenshtein(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestHelpText_SubcommandListing(t *testing.T) {
	out := testTree().Find([]string{"items"}).HelpText()
	for _, want := range []string{
		"usage: items [list | show <id>]",
		"commands:",
		"show <id>",
		"show one item",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("items help missing %q:\n%s", want, out)
		}
	}
	// The footer belongs to the root only.
	if strings.Contains(out, "footer line") {
		t.Errorf("child help should not render the root footer:\n%s", out)
	}
}
