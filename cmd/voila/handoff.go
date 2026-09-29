// handoff.go wires CLI registry credentials into voilad before commands that
// need remote registry access (push/pull/run).
package main

import (
	"context"

	"voila/internal/cli"
)

// handoffRegistryCreds persists registry URL + token for voilad and pushes
// them to a running daemon when the socket answers. Errors are returned to
// the caller; registry URL unset is a no-op.
func handoffRegistryCreds(cfg Config, rootFlag, socketFlag string) error {
	registryURL := resolveRegistry("")
	if registryURL == "" {
		return nil
	}
	root := cli.ResolveRoot(rootFlag, cfg.Root)
	socket := cli.ResolveSocket(socketFlag, cfg.Socket, cli.RootExplicit(rootFlag), root)
	return cli.HandoffRegistryCreds(context.Background(), socket, root, registryURL, resolveRegistryToken())
}
