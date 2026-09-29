// registry_helpers.go holds voilad's local copy of the registry client-side
// helpers (resolveRegistry, registryPuller, asPuller). These mirror the
// helpers that live in cmd/voila — the spec keeps them CLI-side rather than
// promoting them to a shared package, so the daemon ships its own small copy.
//
// They are tiny: a flag/env precedence one-liner + a one-method ManifestPuller
// adapter around *registry.Client + a nil-aware constructor.

package main

import (
	"context"
	"os"

	"voila/internal/cli"
	"voila/internal/imagestore"
	voilapb "voila/internal/proto"
	"voila/internal/registry"
)

// resolveRegistry mirrors cli.ResolveRoot for the registry URL precedence:
//
//  1. -registry flag value, if non-empty
//  2. $VOILA_REGISTRY, if set
//  3. <root>/registry.creds (CLI handoff), if present
//  4. "" (unset)
//
// A non-empty return means the daemon should wrap the chunk store in a
// CachedStore + enable the auto-pull branch of makeResolve. "" means the
// registry was not requested.
func resolveRegistry(flag, root string) string {
	if flag != "" {
		return flag
	}
	if env := os.Getenv("VOILA_REGISTRY"); env != "" {
		return env
	}
	if rc, err := cli.LoadRegistryCreds(root); err == nil {
		return rc.Registry
	}
	return ""
}

// resolveRegistryToken returns the bearer API key handed off from the CLI
// via <root>/registry.creds. The daemon does not read $VOILA_REGISTRY_TOKEN;
// the CLI is the single auth configuration point.
func resolveRegistryToken(root string) string {
	if rc, err := cli.LoadRegistryCreds(root); err == nil {
		return rc.Token
	}
	return ""
}

// registryPuller adapts a *registry.Client to the imagestore.ManifestPuller
// interface. The imagestore.ManifestPuller.GetImage signature matches
// registry.Client.GetImageManifest (HTTP fetch + protobuf unmarshal); the
// indirection lets imagestore avoid importing internal/registry.
//
// The zero-value wrapper (with a nil *registry.Client) must NOT be passed
// as a non-nil imagestore.ManifestPuller — Go would wrap the nil-typed
// pointer into a non-nil interface, defeating imagestore.AutoPull's nil
// short-circuit. Callers therefore use asPuller, which returns a truly-nil
// interface when client is nil.
type registryPuller struct {
	c *registry.Client
}

// GetImage satisfies imagestore.ManifestPuller.
func (p registryPuller) GetImage(ctx context.Context, ref string) (*voilapb.ImageManifest, error) {
	return p.c.GetImageManifest(ctx, ref)
}

// asPuller returns nil when client is nil (so auto-pull short-circuits),
// otherwise wraps client in a registryPuller.
func asPuller(client *registry.Client) imagestore.ManifestPuller {
	if client == nil {
		return nil
	}
	return registryPuller{c: client}
}
