// logincreds.go implements the XDG login credentials file (~/.config/voila/credentials).
// The CLI reads it as a fallback when $VOILA_REGISTRY / $VOILA_REGISTRY_TOKEN are unset.
package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// DefaultRegistryURL is the hosted voila-registry base when login is run
// interactively without a URL argument.
const DefaultRegistryURL = "https://drift-registry-production.up.railway.app/registry"

// LoginCreds is the on-disk login payload under the XDG config dir.
type LoginCreds struct {
	Registry string `json:"registry"`
	Token    string `json:"token"`
}

// LoginCredsPath returns ~/.config/voila/credentials (via os.UserConfigDir).
func LoginCredsPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "voila", "credentials"), nil
}

// NormalizeRegistryURL trims trailing slashes and appends /registry when the
// origin does not already end with /registry.
func NormalizeRegistryURL(raw string) string {
	s := strings.TrimRight(strings.TrimSpace(raw), "/")
	if s == "" {
		return ""
	}
	if strings.HasSuffix(s, "/registry") {
		return s
	}
	return s + "/registry"
}

// LoadLoginCreds reads the login file. A missing file returns the zero value
// and nil error.
func LoadLoginCreds() (LoginCreds, error) {
	var lc LoginCreds
	path, err := LoginCredsPath()
	if err != nil {
		return lc, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return lc, nil
		}
		return lc, err
	}
	if err := json.Unmarshal(data, &lc); err != nil {
		return lc, fmt.Errorf("parse %s: %w", path, err)
	}
	return lc, nil
}

// SaveLoginCreds persists registry URL + token with 0600 perms.
func SaveLoginCreds(registryURL, token string) error {
	if registryURL == "" {
		return errors.New("registry URL is required")
	}
	if token == "" {
		return errors.New("API key is required")
	}
	path, err := LoginCredsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir config dir: %w", err)
	}
	data, err := json.Marshal(LoginCreds{Registry: registryURL, Token: token})
	if err != nil {
		return err
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// DeleteLoginCreds removes the login file. A missing file is not an error.
func DeleteLoginCreds() error {
	path, err := LoginCredsPath()
	if err != nil {
		return err
	}
	err = os.Remove(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// ProbeRegistryAuth checks the API key by POSTing to /v1/chunks/missing
// with an empty id list. A 401 means the key is invalid; any other 2xx/4xx
// (except 401) is treated as success for auth purposes.
func ProbeRegistryAuth(ctx context.Context, registryURL, token string) error {
	base := strings.TrimRight(registryURL, "/")
	body := []byte(`{"ids":[]}`)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/chunks/missing", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return errors.New("invalid API key (registry returned 401)")
	}
	return nil
}
