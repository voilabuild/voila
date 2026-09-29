//go:build !linux

package ingest

import (
	"context"
	"errors"

	"voila/internal/chunkstore"
)

// WalkOverlayUpper is only available on Linux.
func WalkOverlayUpper(ctx context.Context, store chunkstore.ChunkStore, upperDir string) (*LayerWalkResult, error) {
	return nil, errors.New("ingest: WalkOverlayUpper requires linux")
}
