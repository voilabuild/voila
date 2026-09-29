// registrycreds.go implements the CLI → voilad registry credential handoff.
// The CLI is the only place the user configures VOILA_REGISTRY /
// VOILA_REGISTRY_TOKEN; it persists URL + token to <root>/registry.creds
// (0600) and pushes the same values to a running daemon via SetRegistry RPC.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	voilapb "voila/internal/proto"
)

const registryCredsFile = "registry.creds"

// RegistryCreds is the on-disk handoff payload written under the voila root.
type RegistryCreds struct {
	Registry string `json:"registry"`
	Token    string `json:"token"`
}

// RegistryCredsPath returns <root>/registry.creds.
func RegistryCredsPath(root string) string {
	return filepath.Join(root, registryCredsFile)
}

// WriteRegistryCreds persists registry URL + token under root with 0600 perms.
// registryURL must be non-empty. token may be empty (public manifest reads).
func WriteRegistryCreds(root, registryURL, token string) error {
	if registryURL == "" {
		return errors.New("registry URL is required")
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return fmt.Errorf("mkdir voila root: %w", err)
	}
	data, err := json.Marshal(RegistryCreds{Registry: registryURL, Token: token})
	if err != nil {
		return err
	}
	data = append(data, '\n')
	path := RegistryCredsPath(root)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// LoadRegistryCreds reads <root>/registry.creds. A missing file returns the
// zero value and nil error.
func LoadRegistryCreds(root string) (RegistryCreds, error) {
	var rc RegistryCreds
	data, err := os.ReadFile(RegistryCredsPath(root))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return rc, nil
		}
		return rc, err
	}
	if err := json.Unmarshal(data, &rc); err != nil {
		return rc, fmt.Errorf("parse %s: %w", RegistryCredsPath(root), err)
	}
	return rc, nil
}

// HandoffRegistryCreds writes registry creds to the voila root and, when a
// daemon answers on socket, pushes them via SetRegistry RPC. When the daemon
// is down, persisting the file alone is sufficient for the next voilad start
// or a later run after the daemon comes up.
func HandoffRegistryCreds(ctx context.Context, socket, root, registryURL, token string) error {
	if registryURL == "" {
		return nil
	}
	if err := WriteRegistryCreds(root, registryURL, token); err != nil {
		return err
	}
	if TryProbe(socket) != nil {
		return nil
	}
	conn, client, err := DialWorker(socket)
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = client.SetRegistry(ctx, &voilapb.SetRegistryRequest{
		RegistryUrl: registryURL,
		Token:       token,
	})
	return err
}
