package dockerfile

import (
	"strings"
	"testing"
)

func TestParseClassicDockerfile(t *testing.T) {
	df := strings.Join([]string{
		"# comment",
		"FROM alpine:3.20 AS builder",
		"RUN echo hi \\",
		"  && ls",
		"COPY . /src",
		"WORKDIR /src",
		"ENV FOO=bar BAZ=qux",
		"CMD [\"/bin/sh\"]",
		"",
		"FROM scratch",
		"COPY --from=builder /src/foo /foo",
	}, "\n")
	f, err := Parse(strings.NewReader(df))
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Stages) != 2 {
		t.Fatalf("stages: got %d want 2", len(f.Stages))
	}
	if f.Stages[0].Name != "builder" {
		t.Fatalf("stage name: %q", f.Stages[0].Name)
	}
	if f.Stages[0].From.Image != "alpine:3.20" {
		t.Fatalf("from image: %q", f.Stages[0].From.Image)
	}
	if len(f.Stages[0].Instructions) != 5 {
		t.Fatalf("builder instructions: %d", len(f.Stages[0].Instructions))
	}
	run, ok := f.Stages[0].Instructions[0].(*Run)
	if !ok {
		t.Fatalf("first inst: %T", f.Stages[0].Instructions[0])
	}
	if !strings.Contains(run.Raw, "echo hi") || !strings.Contains(run.Raw, "&& ls") {
		t.Fatalf("run raw: %q", run.Raw)
	}
	copyInst, ok := f.Stages[1].Instructions[0].(*Copy)
	if !ok {
		t.Fatalf("copy: %T", f.Stages[1].Instructions[0])
	}
	if copyInst.From != "builder" {
		t.Fatalf("copy from: %q", copyInst.From)
	}
}

func TestParseExecForm(t *testing.T) {
	f, err := Parse(strings.NewReader("FROM scratch\nENTRYPOINT [\"echo\", \"hi\"]\n"))
	if err != nil {
		t.Fatal(err)
	}
	ep, ok := f.Stages[0].Instructions[0].(*Entrypoint)
	if !ok {
		t.Fatal("not entrypoint")
	}
	if len(ep.Argv) != 2 || ep.Argv[0] != "echo" {
		t.Fatalf("argv: %v", ep.Argv)
	}
}

func TestCanonical(t *testing.T) {
	c := Canonical(&Copy{Sources: []string{"."}, Dest: "/app", From: "build"})
	if !strings.Contains(c, "COPY") {
		t.Fatal(c)
	}
}
