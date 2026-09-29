package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"voila/internal/cli"
)

func TestCmdLogout(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := cli.SaveLoginCreds("https://example.com/registry", "dreg_test"); err != nil {
		t.Fatal(err)
	}
	cfg := Config{Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}
	if err := cmdLogout(cfg, nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "voila", "credentials")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("credentials file still exists after logout: %v", err)
	}
}
