package cli

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeRegistryURL(t *testing.T) {
	tests := []struct {
		in, want string
	}{
		{"https://example.com", "https://example.com/registry"},
		{"https://example.com/", "https://example.com/registry"},
		{"https://example.com/registry", "https://example.com/registry"},
		{"https://example.com/registry/", "https://example.com/registry"},
		{"  https://host/app/registry/  ", "https://host/app/registry"},
	}
	for _, tc := range tests {
		got := NormalizeRegistryURL(tc.in)
		if got != tc.want {
			t.Errorf("NormalizeRegistryURL(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSaveLoadDeleteLoginCreds(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)

	const url = "https://example.com/registry"
	const tok = "dreg_test_key"

	if err := SaveLoginCreds(url, tok); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "voila", "credentials")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("perms = %o, want 0600", info.Mode().Perm())
	}

	lc, err := LoadLoginCreds()
	if err != nil {
		t.Fatal(err)
	}
	if lc.Registry != url || lc.Token != tok {
		t.Fatalf("loaded %+v, want registry=%q token=%q", lc, url, tok)
	}

	if err := DeleteLoginCreds(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("after delete: stat %s: %v", path, err)
	}
}

func TestProbeRegistryAuth(t *testing.T) {
	const goodTok = "dreg_good"
	srv := httptest.NewServer(http.StripPrefix("/registry", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chunks/missing" || r.Method != http.MethodPost {
			http.NotFound(w, r)
			return
		}
		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+goodTok {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"missing":[]}`))
	})))
	defer srv.Close()

	base := srv.URL + "/registry"
	ctx := context.Background()

	if err := ProbeRegistryAuth(ctx, base, ""); err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("empty token: err = %v, want 401", err)
	}
	if err := ProbeRegistryAuth(ctx, base, "dreg_bad"); err == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("bad token: err = %v, want 401", err)
	}
	if err := ProbeRegistryAuth(ctx, base, goodTok); err != nil {
		t.Errorf("good token: %v", err)
	}
}
