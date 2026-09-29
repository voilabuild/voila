// args.go implements the argv pre-pass that lets flags appear AFTER
// positional arguments. stdlib flag stops parsing at the first non-flag
// token, which made documented synopsis forms like
//
//	voila pull <ref> [-registry URL] [-root dir]
//
// unusable as written (the trailing flags produced a bare usage error).
// Command.Execute runs every leaf's argv through ReorderArgs before handing
// it to the command's Run, so both orders parse identically everywhere.
package cli

// ReorderArgs restates args so flag-like tokens precede positional ones,
// preserving relative order. A "--" terminator stops the scan: it and
// everything after it keep their place verbatim, so commands like
// `run <ref> -- <cmd...>` never have container argv reordered.
//
// Heuristic: a flag token followed by a non-flag token treats that token as
// its value and moves the pair together (`-registry https://x`). This is
// what makes value-taking flags survive the move; the cost is that a
// boolean flag directly followed by a positional is read as a pair, which
// does not occur in voila's documented synopsis shapes (flags trail the
// positionals they belong to).
func ReorderArgs(args []string) []string {
	for i, a := range args {
		if a == "--" {
			return append(reorderFlags(args[:i]), args[i:]...)
		}
	}
	return reorderFlags(args)
}

// reorderFlags is the flag-first restatement applied to the pre-terminator
// prefix of argv.
func reorderFlags(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if len(a) > 1 && a[0] == '-' {
			flags = append(flags, a)
			if i+1 < len(args) && !isFlagLike(args[i+1]) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

// isFlagLike reports whether a looks like a flag token rather than a
// positional or terminator.
func isFlagLike(a string) bool {
	if len(a) <= 1 || a[0] != '-' {
		return false
	}
	return true
}
