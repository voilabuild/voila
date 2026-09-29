// command.go implements voila's minimal command framework: a declarative
// Command tree that drives BOTH dispatch and help rendering, so the command
// table has a single source of truth (the hand-written usage text this
// replaces was free to rot every time a flag changed).
//
// It is deliberately not cobra: no external dependencies (plan §2), no flag
// parsing takeover — each command keeps parsing its own flags via NewFlagSet,
// and the tree only routes argv words to Run funcs and renders help.
package cli

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

// Command describes one CLI command (or nested subcommand) for dispatch and
// help rendering. A node with Subs routes matching argv words to the child;
// otherwise (or when nothing matches) argv goes to Run verbatim — including
// any flags, which the Run func parses itself.
type Command struct {
	// Name is the word typed on the command line ("ingest", "prune", …).
	Name string
	// Usage is the synopsis of everything after the name, e.g.
	// "<tarball> [-ref override] [-root dir]". Shown in help output.
	Usage string
	// Short is the one-line description shown under the command in its
	// parent's help listing.
	Short string
	// Subs are the optional nested subcommands, matched against argv[0].
	Subs []*Command
	// Run executes the command with the argv remaining after the command
	// word(s). It owns flag parsing. A nil Run marks a grouping/help-only
	// node (running it prints help).
	Run func(args []string) error
	// Footer is trailing help text printed after the command listing.
	// Only ever set on the root node; zero value renders nothing.
	Footer string
}

// ErrUnknownCommand reports that argv named a command the tree does not know.
// The caller maps it to its "usage error" exit code (voila uses 2); Execute
// has already printed the message + help to the writer.
var ErrUnknownCommand = errors.New("unknown command")

// ErrUsage reports that argv was empty for a node without a Run of its own
// (e.g. bare `voila`). Help has been printed; map to the same exit code as
// ErrUnknownCommand.
var ErrUsage = errors.New("usage")

// Execute routes argv (the program name already stripped) through the tree.
//
//   - argv empty: prints help, returns ErrUsage (or calls Run([]) when the
//     node has one — e.g. bare `voila images` lists).
//   - argv[0] names a child: recurse with the child word consumed.
//   - otherwise: the node's Run gets the full argv, reordered so trailing
//     flags parse (see ReorderArgs); a node without Run prints "unknown
//     command" (+ did-you-mean) and help, returning ErrUnknownCommand.
//
// Only routing errors are printed here; errors bubbling up from Run belong
// to the caller (it knows the exit-code and prefixing conventions).
func (c *Command) Execute(w io.Writer, argv []string) error {
	if len(argv) == 0 {
		if c.Run == nil {
			fmt.Fprint(w, c.HelpText())
			return ErrUsage
		}
		return c.Run(nil)
	}
	for _, sub := range c.Subs {
		if sub.Name == argv[0] {
			return sub.Execute(w, argv[1:])
		}
	}
	if c.Run == nil {
		fmt.Fprintf(w, "%s: unknown command %q\n", c.Name, argv[0])
		if near := Similar(c.subNames(), argv[0], 2); len(near) > 0 {
			fmt.Fprintf(w, "\nDid you mean:\n")
			for _, s := range near {
				fmt.Fprintf(w, "  %s %s\n", c.Name, s)
			}
			fmt.Fprintln(w)
		}
		fmt.Fprint(w, c.HelpText())
		return ErrUnknownCommand
	}
	return c.Run(ReorderArgs(argv))
}

// Find walks path through the tree, returning the deepest matching node
// (nil when the path leaves the tree). Used by `help <cmd...>`.
func (c *Command) Find(path []string) *Command {
	cur := c
	for _, word := range path {
		var next *Command
		for _, sub := range cur.Subs {
			if sub.Name == word {
				next = sub
				break
			}
		}
		if next == nil {
			return nil
		}
		cur = next
	}
	return cur
}

// HelpText renders the node's help using its own name (see helpText).
func (c *Command) HelpText() string {
	return c.helpText(c.Name)
}

// HelpTextFor renders the node's help with fullName as the displayed
// command path (e.g. "voila images"), for `help <cmd...>` output.
func (c *Command) HelpTextFor(fullName string) string {
	return c.helpText(fullName)
}

// helpText renders the node's help: usage lines, description, the child
// command listing (when present), and the footer (root only). fullName is
// the space-joined path from the program name ("voila", "voila images"),
// so nested nodes can render their fully-qualified usage line.
func (c *Command) helpText(fullName string) string {
	var b strings.Builder
	switch {
	case c.Usage != "":
		fmt.Fprintf(&b, "usage: %s %s\n", fullName, c.Usage)
		if len(c.Subs) > 0 {
			fmt.Fprintf(&b, "       %s <command> [args]\n", fullName)
		}
	case len(c.Subs) > 0:
		fmt.Fprintf(&b, "usage: %s <command> [args]\n", fullName)
	default:
		fmt.Fprintf(&b, "usage: %s\n", fullName)
	}
	if c.Short != "" {
		fmt.Fprintf(&b, "\n%s\n", c.Short)
	}
	if len(c.Subs) > 0 {
		b.WriteString("\ncommands:\n")
		width := 0
		for _, sub := range c.Subs {
			if n := len(sub.Name) + len(sub.Usage); n > width {
				width = n
			}
		}
		width += 2
		for _, sub := range c.Subs {
			line := sub.Name
			if sub.Usage != "" {
				line += " " + sub.Usage
			}
			fmt.Fprintf(&b, "  %-*s%s\n", width, line, sub.Short)
		}
	}
	if c.Footer != "" {
		fmt.Fprintf(&b, "\n%s\n", c.Footer)
	}
	return b.String()
}

// subNames returns the child names, for did-you-mean matching.
func (c *Command) subNames() []string {
	names := make([]string, len(c.Subs))
	for i, sub := range c.Subs {
		names[i] = sub.Name
	}
	return names
}

// Similar returns the names within levenshtein distance maxDist of target
// (or that start with it), closest first. Ties keep table order.
func Similar(names []string, target string, maxDist int) []string {
	type scored struct {
		name  string
		dist  int
		order int
	}
	var hits []scored
	for i, n := range names {
		d := levenshtein(n, target)
		if strings.HasPrefix(n, target) && target != "" {
			d = 0 // a prefix is always a plausible typo completion
		}
		if d <= maxDist {
			hits = append(hits, scored{n, d, i})
		}
	}
	// Stable sort by distance.
	for i := 1; i < len(hits); i++ {
		for j := i; j > 0 && hits[j].dist < hits[j-1].dist; j-- {
			hits[j], hits[j-1] = hits[j-1], hits[j]
		}
	}
	out := make([]string, len(hits))
	for i, h := range hits {
		out[i] = h.name
	}
	return out
}

// levenshtein is the classic edit distance (insert/delete/substitute),
// bounded-input simple version — command names are tiny.
func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	prev := make([]int, len(rb)+1)
	cur := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			cost := 1
			if ra[i-1] == rb[j-1] {
				cost = 0
			}
			cur[j] = min3(cur[j-1]+1, prev[j]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(rb)]
}

func min3(a, b, c int) int {
	if b < a {
		a = b
	}
	if c < a {
		a = c
	}
	return a
}
