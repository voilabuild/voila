package ingest

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"voila/internal/chunkstore"
)

func TestWalkDirSingleFile(t *testing.T) {
	root := t.TempDir()
	store, err := chunkstore.OpenLocal(root)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	ctxDir := filepath.Join(root, "ctx")
	if err := os.MkdirAll(ctxDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ctxDir, "hello.txt"), []byte("hello world"), 0o644); err != nil {
		t.Fatal(err)
	}

	res, err := WalkDir(context.Background(), store, WalkDirOptions{
		ContextDir: ctxDir,
		Sources:    []string{"hello.txt"},
		Dest:       "/",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Tree.Lookup("hello.txt") == nil {
		t.Fatal("hello.txt not in layer tree")
	}
}
