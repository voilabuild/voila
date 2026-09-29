package worker

import (
	"context"
	"errors"
	"testing"

	"voila/internal/chunkstore"
)

func TestRegistryHub_GetChunkWithoutClient(t *testing.T) {
	hub := NewRegistryHub()
	_, err := hub.GetChunk(context.Background(), chunkstore.ChunkID{})
	if err == nil {
		t.Fatal("expected error without configured client")
	}
	if !errors.Is(err, chunkstore.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

func TestRegistryHub_ConfigureClears(t *testing.T) {
	hub := NewRegistryHub()
	if err := hub.Configure("http://127.0.0.1:1", ""); err != nil {
		t.Fatal(err)
	}
	if hub.Client() == nil {
		t.Fatal("expected client")
	}
	if err := hub.Configure("", ""); err != nil {
		t.Fatal(err)
	}
	if hub.Client() != nil {
		t.Fatal("expected nil client after clear")
	}
}
