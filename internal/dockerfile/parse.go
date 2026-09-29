// Package dockerfile parses classic (pre-BuildKit) Dockerfiles: FROM, RUN,
// COPY, ENV, and the other instructions voila build v1 supports. It is
// hand-rolled and stdlib-only (plan §2).
package dockerfile

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"unicode"
)

// File is a parsed Dockerfile: an ordered list of stages, each with a name
// ("" for the default final stage) and its instructions.
type File struct {
	Stages []Stage
}

// Stage is one build stage beginning at a FROM instruction.
type Stage struct {
	Name         string // AS alias, or "" when unnamed
	From         *From
	Instructions []Instruction
}

// Instruction is one Dockerfile directive.
type Instruction interface {
	Kind() string
}

// From starts a stage.
type From struct {
	Image    string
	As       string
	Platform string
}

func (From) Kind() string { return "FROM" }

// Arg declares a build-time variable.
type Arg struct {
	Name         string
	DefaultValue string
}

func (Arg) Kind() string { return "ARG" }

// Env sets environment variables (KEY=val or KEY val).
type Env struct {
	Vars map[string]string
}

func (Env) Kind() string { return "ENV" }

// Workdir sets the working directory.
type Workdir struct {
	Path string
}

func (Workdir) Kind() string { return "WORKDIR" }

// User sets the runtime user.
type User struct {
	User string
}

func (User) Kind() string { return "USER" }

// Copy copies files from build context or another stage.
type Copy struct {
	Sources []string
	Dest    string
	From    string // --from stage name
	Chown   string
	Chmod   string
}

func (Copy) Kind() string { return "COPY" }

// Add is like Copy (local paths only in v1).
type Add struct {
	Sources []string
	Dest    string
	Chown   string
	Chmod   string
}

func (Add) Kind() string { return "ADD" }

// Run executes a command during build.
type Run struct {
	Argv []string // exec form, or shell expanded to [shell, -c, cmd]
	Raw  string   // canonical text for cache keys
}

func (Run) Kind() string { return "RUN" }

// Cmd sets default command.
type Cmd struct {
	Argv []string
	Raw  string
}

func (Cmd) Kind() string { return "CMD" }

// Entrypoint sets the entrypoint.
type Entrypoint struct {
	Argv []string
	Raw  string
}

func (Entrypoint) Kind() string { return "ENTRYPOINT" }

// Label sets image labels.
type Label struct {
	Labels map[string]string
}

func (Label) Kind() string { return "LABEL" }

// Expose documents a port.
type Expose struct {
	Ports []string
}

func (Expose) Kind() string { return "EXPOSE" }

// Volume declares a volume mount point.
type Volume struct {
	Paths []string
}

func (Volume) Kind() string { return "VOLUME" }

// StopSignal sets the stop signal.
type StopSignal struct {
	Signal string
}

func (StopSignal) Kind() string { return "STOPSIGNAL" }

// Healthcheck stores a HEALTHCHECK directive (not executed at build time).
type Healthcheck struct {
	Disable bool
	// Remaining fields stored as raw for config serialization.
	Raw string
}

func (Healthcheck) Kind() string { return "HEALTHCHECK" }

// Shell overrides the default shell for RUN.
type Shell struct {
	Argv []string
}

func (Shell) Kind() string { return "SHELL" }

// Onbuild is unsupported in v1 but parsed for a clear error.
type Onbuild struct {
	Inner Instruction
}

func (Onbuild) Kind() string { return "ONBUILD" }

// Parse reads and parses a Dockerfile from r.
func Parse(r io.Reader) (*File, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	lines := unfoldLines(string(data))
	f := &File{}
	var stage *Stage
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		inst, err := parseLine(line)
		if err != nil {
			return nil, fmt.Errorf("dockerfile line %d: %w", i+1, err)
		}
		if _, ok := inst.(*From); ok {
			if stage != nil {
				f.Stages = append(f.Stages, *stage)
			}
			from := inst.(*From)
			stage = &Stage{Name: from.As, From: from}
			continue
		}
		if stage == nil {
			return nil, fmt.Errorf("dockerfile line %d: instruction before first FROM", i+1)
		}
		stage.Instructions = append(stage.Instructions, inst)
	}
	if stage != nil {
		f.Stages = append(f.Stages, *stage)
	}
	if len(f.Stages) == 0 {
		return nil, fmt.Errorf("dockerfile: no FROM instruction")
	}
	return f, nil
}

// unfoldLines joins backslash continuations and strips comments.
func unfoldLines(s string) []string {
	var out []string
	var buf strings.Builder
	for _, raw := range strings.Split(s, "\n") {
		line := raw
		if idx := strings.Index(line, "#"); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimRight(line, " \t\r")
		if strings.HasSuffix(line, "\\") {
			buf.WriteString(strings.TrimSuffix(line, "\\"))
			buf.WriteByte(' ')
			continue
		}
		buf.WriteString(line)
		if buf.Len() > 0 {
			out = append(out, buf.String())
			buf.Reset()
		}
	}
	if buf.Len() > 0 {
		out = append(out, buf.String())
	}
	return out
}

func parseLine(line string) (Instruction, error) {
	fields := splitFields(line)
	if len(fields) == 0 {
		return nil, fmt.Errorf("empty instruction")
	}
	op := strings.ToUpper(fields[0])
	rest := strings.TrimSpace(line[len(fields[0]):])
	switch op {
	case "FROM":
		return parseFrom(rest)
	case "ARG":
		return parseArg(rest)
	case "ENV":
		return parseKVInstruction("ENV", rest)
	case "LABEL":
		return parseKVInstruction("LABEL", rest)
	case "WORKDIR":
		p, err := parseSinglePath(rest)
		if err != nil {
			return nil, err
		}
		return &Workdir{Path: p}, nil
	case "USER":
		u := strings.TrimSpace(rest)
		if u == "" {
			return nil, fmt.Errorf("USER requires a username")
		}
		return &User{User: u}, nil
	case "COPY":
		return parseCopy(rest, false)
	case "ADD":
		return parseCopy(rest, true)
	case "RUN":
		argv, raw, err := parseCmdInstruction(rest)
		if err != nil {
			return nil, err
		}
		return &Run{Argv: argv, Raw: raw}, nil
	case "CMD":
		argv, raw, err := parseCmdInstruction(rest)
		if err != nil {
			return nil, err
		}
		return &Cmd{Argv: argv, Raw: raw}, nil
	case "ENTRYPOINT":
		argv, raw, err := parseCmdInstruction(rest)
		if err != nil {
			return nil, err
		}
		return &Entrypoint{Argv: argv, Raw: raw}, nil
	case "EXPOSE":
		ports, err := parseExpose(rest)
		if err != nil {
			return nil, err
		}
		return &Expose{Ports: ports}, nil
	case "VOLUME":
		paths, err := parseVolume(rest)
		if err != nil {
			return nil, err
		}
		return &Volume{Paths: paths}, nil
	case "STOPSIGNAL":
		sig := strings.TrimSpace(rest)
		if sig == "" {
			return nil, fmt.Errorf("STOPSIGNAL requires a signal name")
		}
		return &StopSignal{Signal: sig}, nil
	case "HEALTHCHECK":
		return parseHealthcheck(rest)
	case "SHELL":
		argv, _, err := parseCmdInstruction(rest)
		if err != nil {
			return nil, err
		}
		if len(argv) == 0 {
			return nil, fmt.Errorf("SHELL requires a command")
		}
		return &Shell{Argv: argv}, nil
	case "ONBUILD":
		inner, err := parseLine(rest)
		if err != nil {
			return nil, err
		}
		return &Onbuild{Inner: inner}, nil
	default:
		return nil, fmt.Errorf("unsupported instruction %q", op)
	}
}

func parseFrom(rest string) (*From, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return nil, fmt.Errorf("FROM requires an image name")
	}
	f := &From{}
	tokens := splitFields(rest)
	i := 0
	if strings.HasPrefix(strings.ToUpper(tokens[0]), "--PLATFORM=") {
		f.Platform = tokens[0][len("--platform="):]
		i++
	} else if len(tokens) > 1 && strings.EqualFold(tokens[0], "--platform") {
		f.Platform = tokens[1]
		i += 2
	}
	if i >= len(tokens) {
		return nil, fmt.Errorf("FROM requires an image name")
	}
	f.Image = tokens[i]
	i++
	for j := i; j < len(tokens)-1; j++ {
		if strings.EqualFold(tokens[j], "AS") {
			f.As = tokens[j+1]
			break
		}
	}
	return f, nil
}

func parseArg(rest string) (*Arg, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return nil, fmt.Errorf("ARG requires a name")
	}
	name, val, _ := strings.Cut(rest, "=")
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, fmt.Errorf("ARG requires a name")
	}
	return &Arg{Name: name, DefaultValue: strings.TrimSpace(val)}, nil
}

func parseKVInstruction(kind, rest string) (Instruction, error) {
	m, err := parseKeyValues(rest)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", kind, err)
	}
	if len(m) == 0 {
		return nil, fmt.Errorf("%s requires at least one key", kind)
	}
	switch kind {
	case "ENV":
		return &Env{Vars: m}, nil
	default:
		return &Label{Labels: m}, nil
	}
}

func parseKeyValues(rest string) (map[string]string, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return nil, fmt.Errorf("empty key-value list")
	}
	if strings.HasPrefix(rest, "[") {
		return nil, fmt.Errorf("JSON array form not supported for this instruction in v1")
	}
	out := make(map[string]string)
	tokens := splitFields(rest)
	for i := 0; i < len(tokens); i++ {
		tok := tokens[i]
		if key, val, ok := strings.Cut(tok, "="); ok {
			out[key] = val
			continue
		}
		if i+1 >= len(tokens) {
			return nil, fmt.Errorf("key %q requires a value", tok)
		}
		out[tok] = tokens[i+1]
		i++
	}
	return out, nil
}

func parseCopy(rest string, add bool) (Instruction, error) {
	flags, args, err := parseFlags(rest)
	if err != nil {
		return nil, err
	}
	if len(args) < 2 {
		return nil, fmt.Errorf("COPY/ADD requires at least one source and a destination")
	}
	dest := args[len(args)-1]
	sources := args[:len(args)-1]
	c := &Copy{
		Sources: sources,
		Dest:    dest,
		From:    flags["from"],
		Chown:   flags["chown"],
		Chmod:   flags["chmod"],
	}
	if add {
		return &Add{
			Sources: c.Sources,
			Dest:    c.Dest,
			Chown:   c.Chown,
			Chmod:   c.Chmod,
		}, nil
	}
	return c, nil
}

func parseFlags(rest string) (map[string]string, []string, error) {
	flags := make(map[string]string)
	var args []string
	for _, tok := range splitFields(rest) {
		if strings.HasPrefix(tok, "--") {
			key, val, ok := strings.Cut(tok[2:], "=")
			if !ok {
				return nil, nil, fmt.Errorf("flag %q requires =value form", tok)
			}
			flags[strings.ToLower(key)] = val
			continue
		}
		args = append(args, tok)
	}
	return flags, args, nil
}

func parseCmdInstruction(rest string) ([]string, string, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return nil, "", fmt.Errorf("empty command")
	}
	if rest[0] == '[' {
		argv, err := parseJSONArray(rest)
		if err != nil {
			return nil, "", err
		}
		return argv, rest, nil
	}
	// Shell form: the whole rest is one shell command string.
	return nil, rest, nil
}

func parseJSONArray(s string) ([]string, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "[") || !strings.HasSuffix(s, "]") {
		return nil, fmt.Errorf("malformed JSON array")
	}
	var out []string
	inner := strings.TrimSpace(s[1 : len(s)-1])
	if inner == "" {
		return out, nil
	}
	i := 0
	for i < len(inner) {
		inner = strings.TrimLeft(inner[i:], " \t,")
		i = 0
		if inner == "" {
			break
		}
		if inner[0] != '"' {
			return nil, fmt.Errorf("JSON array elements must be quoted strings")
		}
		var buf strings.Builder
		escaped := false
		j := 1
		for j < len(inner) {
			c := inner[j]
			if escaped {
				buf.WriteByte(c)
				escaped = false
				j++
				continue
			}
			if c == '\\' {
				escaped = true
				j++
				continue
			}
			if c == '"' {
				break
			}
			buf.WriteByte(c)
			j++
		}
		if j >= len(inner) || inner[j] != '"' {
			return nil, fmt.Errorf("unterminated string in JSON array")
		}
		out = append(out, buf.String())
		i = j + 1
		inner = inner[i:]
		i = 0
	}
	return out, nil
}

func parseExpose(rest string) ([]string, error) {
	tokens := splitFields(rest)
	if len(tokens) == 0 {
		return nil, fmt.Errorf("EXPOSE requires at least one port")
	}
	return tokens, nil
}

func parseVolume(rest string) ([]string, error) {
	if strings.HasPrefix(strings.TrimSpace(rest), "[") {
		return parseJSONArray(rest)
	}
	tokens := splitFields(rest)
	if len(tokens) == 0 {
		return nil, fmt.Errorf("VOLUME requires at least one path")
	}
	return tokens, nil
}

func parseHealthcheck(rest string) (*Healthcheck, error) {
	rest = strings.TrimSpace(rest)
	if strings.EqualFold(rest, "NONE") {
		return &Healthcheck{Disable: true, Raw: "NONE"}, nil
	}
	return &Healthcheck{Raw: rest}, nil
}

func parseSinglePath(rest string) (string, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return "", fmt.Errorf("path is required")
	}
	if strings.HasPrefix(rest, "[") {
		argv, err := parseJSONArray(rest)
		if err != nil {
			return "", err
		}
		if len(argv) != 1 {
			return "", fmt.Errorf("expected exactly one path")
		}
		return argv[0], nil
	}
	tokens := splitFields(rest)
	if len(tokens) != 1 {
		return "", fmt.Errorf("expected exactly one path")
	}
	return tokens[0], nil
}

// splitFields splits a line into whitespace-separated tokens, respecting
// single and double quotes.
func splitFields(s string) []string {
	var out []string
	var buf bytes.Buffer
	inQuote := byte(0)
	escaped := false
	flush := func() {
		if buf.Len() > 0 {
			out = append(out, buf.String())
			buf.Reset()
		}
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if escaped {
			buf.WriteByte(c)
			escaped = false
			continue
		}
		if inQuote != 0 {
			if c == '\\' && inQuote == '"' {
				escaped = true
				continue
			}
			if c == inQuote {
				inQuote = 0
				continue
			}
			buf.WriteByte(c)
			continue
		}
		if c == '"' || c == '\'' {
			inQuote = c
			continue
		}
		if unicode.IsSpace(rune(c)) {
			flush()
			continue
		}
		buf.WriteByte(c)
	}
	flush()
	return out
}

// Canonical returns a stable string representation of an instruction for cache
// keys. The parent merged-root chunk id is mixed in by the caller.
func Canonical(inst Instruction) string {
	switch v := inst.(type) {
	case *Run:
		return "RUN " + v.Raw
	case *Copy:
		return fmt.Sprintf("COPY --from=%s %s -> %s", v.From, strings.Join(v.Sources, " "), v.Dest)
	case *Add:
		return fmt.Sprintf("ADD %s -> %s", strings.Join(v.Sources, " "), v.Dest)
	case *Env:
		return "ENV " + kvCanonical(v.Vars)
	case *Arg:
		return "ARG " + v.Name + "=" + v.DefaultValue
	case *Workdir:
		return "WORKDIR " + v.Path
	case *User:
		return "USER " + v.User
	case *Cmd:
		return "CMD " + v.Raw
	case *Entrypoint:
		return "ENTRYPOINT " + v.Raw
	case *Label:
		return "LABEL " + kvCanonical(v.Labels)
	case *Expose:
		return "EXPOSE " + strings.Join(v.Ports, " ")
	case *Volume:
		return "VOLUME " + strings.Join(v.Paths, " ")
	case *StopSignal:
		return "STOPSIGNAL " + v.Signal
	case *Healthcheck:
		return "HEALTHCHECK " + v.Raw
	case *Shell:
		return "SHELL " + strings.Join(v.Argv, " ")
	default:
		return v.Kind()
	}
}

func kvCanonical(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sortStrings(keys)
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(m[k])
	}
	return b.String()
}

func sortStrings(s []string) {
	for i := 0; i < len(s); i++ {
		for j := i + 1; j < len(s); j++ {
			if s[j] < s[i] {
				s[i], s[j] = s[j], s[i]
			}
		}
	}
}
