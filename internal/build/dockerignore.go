package build

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// Dockerignore returns a matcher for paths relative to the build context root.
// Patterns follow Docker's .dockerignore semantics (simplified classic subset).
func Dockerignore(contextDir string) (func(rel string) bool, error) {
	path := filepath.Join(contextDir, ".dockerignore")
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return func(string) bool { return false }, nil
		}
		return nil, err
	}
	defer f.Close()
	var patterns []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		patterns = append(patterns, line)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return func(rel string) bool {
		rel = filepath.ToSlash(rel)
		for _, p := range patterns {
			if matchIgnore(rel, p) {
				return true
			}
		}
		return false
	}, nil
}

func matchIgnore(rel, pattern string) bool {
	pattern = filepath.ToSlash(pattern)
	if pattern == "" {
		return false
	}
	// Directory-only pattern
	if strings.HasSuffix(pattern, "/") {
		pattern = strings.TrimSuffix(pattern, "/")
		if rel == pattern || strings.HasPrefix(rel, pattern+"/") {
			return true
		}
		return false
	}
	if rel == pattern {
		return true
	}
	if strings.HasPrefix(rel, pattern+"/") {
		return true
	}
	// Simple ** glob: ** at start
	if strings.HasPrefix(pattern, "**/") {
		suffix := pattern[3:]
		if strings.HasSuffix(rel, "/"+suffix) || rel == suffix {
			return true
		}
		if idx := strings.Index(rel, "/"+suffix); idx >= 0 {
			return true
		}
	}
	// basename match
	if filepath.Base(rel) == pattern {
		return true
	}
	return false
}
