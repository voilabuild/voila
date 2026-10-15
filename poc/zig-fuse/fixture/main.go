//go:build zig_fuse_fixture

// Writes the on-disk fixture for poc/zig-fuse (see README).
//
//	go run -tags zig_fuse_fixture ./poc/zig-fuse/fixture -o /tmp/zig-fuse-fixture
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const chunkSize = 1 << 20

func main() {
	out := flag.String("o", "fixture-out", "output directory")
	flag.Parse()
	if err := writeFixture(*out); err != nil {
		fmt.Fprintf(os.Stderr, "write fixture: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "wrote fixture to %s\n", *out)
}

func writeFixture(dir string) error {
	if err := os.MkdirAll(filepath.Join(dir, "chunks"), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "chunks", "a"), filled(0xAA), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "chunks", "c"), filled(0xCC), 0o644); err != nil {
		return err
	}
	tree := "file big.bin 2097152 a c\nsymlink link big.bin\n"
	return os.WriteFile(filepath.Join(dir, "tree.txt"), []byte(tree), 0o644)
}

func filled(b byte) []byte {
	s := make([]byte, chunkSize)
	for i := range s {
		s[i] = b
	}
	return s
}
