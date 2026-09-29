package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"voila/internal/dockerfile"
)

func TestBuildCommandRegistered(t *testing.T) {
	cfg := Config{Stdout: os.Stdout, Stderr: os.Stderr}
	root := newRoot(cfg)
	node := root.Find([]string{"build"})
	if node == nil {
		t.Fatal("build command not in tree")
	}
	if !strings.Contains(node.Short, "Dockerfile") {
		t.Fatalf("short help: %q", node.Short)
	}
}

func TestDockerfileParserScratchCopy(t *testing.T) {
	dir := t.TempDir()
	df := filepath.Join(dir, "Dockerfile")
	if err := os.WriteFile(df, []byte("FROM scratch\nCOPY hello.txt /\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("world"), 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(df)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	parsed, err := dockerfile.Parse(f)
	if err != nil {
		t.Fatal(err)
	}
	if needsDaemon(df, dir) {
		t.Fatal("scratch COPY should not need daemon")
	}
	_ = parsed
}

func TestExtractBuildArgs(t *testing.T) {
	args, m := extractBuildArgs([]string{"--build-arg=FOO=bar", "-t", "img:tag", "."})
	if m["FOO"] != "bar" {
		t.Fatalf("args: %v", m)
	}
	if len(args) != 3 {
		t.Fatalf("filtered: %v", args)
	}
}
