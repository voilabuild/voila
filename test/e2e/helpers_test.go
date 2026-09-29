package e2e_test

import (
	"io/fs"
	"os"
	"path/filepath"
)

// filepathWalkFiles invokes fn once per regular file rooted at root, ignoring
// directories themselves. Missing root is a no-op (no error).
func filepathWalkFiles(root string, fn func(string)) error {
	_, err := os.Stat(root)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		fn(p)
		return nil
	})
}

// realTarballEnv returns the value of VOILA_E2E_TARBALL or "".
func realTarballEnv() string {
	return os.Getenv("VOILA_E2E_TARBALL")
}
