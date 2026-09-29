// registryhub.go holds the daemon's mutable registry client used for lazy
// chunk fetch and auto-pull. The CLI updates it via SetRegistry RPC and/or
// <root>/registry.creds; chunk GETs stay unauthenticated on the wire.
package worker

import (
	"context"
	"fmt"
	"sync"

	"voila/internal/chunkstore"
	"voila/internal/registry"
)

// RegistryHub is a thread-safe, hot-swappable registry client. It implements
// chunkstore.Fetcher so CachedStore can lazy-fetch through a client that
// arrives after voilad starts (CLI handoff).
type RegistryHub struct {
	mu     sync.RWMutex
	url    string
	token  string
	client *registry.Client
}

// NewRegistryHub returns an empty hub. Call Configure before use.
func NewRegistryHub() *RegistryHub {
	return &RegistryHub{}
}

// Configure sets or replaces the registry URL and bearer token. Empty url
// clears the client. Reuses the existing client when url and token are unchanged.
func (h *RegistryHub) Configure(url, token string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if url == "" {
		if h.client != nil {
			h.client.Close()
			h.client = nil
		}
		h.url, h.token = "", ""
		return nil
	}
	if h.client != nil && h.url == url && h.token == token {
		return nil
	}
	if h.client != nil {
		h.client.Close()
		h.client = nil
	}
	c, err := registry.NewClient(url, registry.WithToken(token))
	if err != nil {
		return err
	}
	h.url, h.token, h.client = url, token, c
	return nil
}

// Client returns the current registry client, or nil when unset.
func (h *RegistryHub) Client() *registry.Client {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.client
}

// GetChunk implements chunkstore.Fetcher.
func (h *RegistryHub) GetChunk(ctx context.Context, id chunkstore.ChunkID) ([]byte, error) {
	c := h.Client()
	if c == nil {
		return nil, fmt.Errorf("%w: no registry configured", chunkstore.ErrNotFound)
	}
	return c.GetChunk(ctx, id)
}
