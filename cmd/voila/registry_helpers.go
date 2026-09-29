// registry_helpers.go holds the registry client-side helpers that stay with
// the CLI binary in the three-binary split: resolveRegistry (flag/env
// precedence for the remote registry URL) and registryPuller (the
// imagestore.ManifestPuller adapter over a *registry.Client). They live here
// (not in internal/cli) because they are conceptually "client of the remote
// registry" plumbing used by `voila push` / `voila pull` only.
//
// The `voilad` daemon ships its own small copies of these helpers since the
// spec keeps them CLI-side rather than promoting them to a shared package.

package main

import (
	"context"
	"os"
	"strconv"

	"voila/internal/cli"
	voilapb "voila/internal/proto"
	"voila/internal/registry"
)

// resolveRegistry mirrors cli.ResolveRoot for the registry URL precedence:
//
//  1. -registry flag value, if non-empty
//  2. $VOILA_REGISTRY, if set
//  3. ~/.config/voila/credentials (from `voila login`), if present
//  4. "" (unset)
//
// A non-empty return means the calling command should wrap its store in a
// CachedStore + enable auto-pull in the resolve closure. "" means the
// registry was not requested for that command (push/pull treat empty as an
// error; run/mount/worker treat empty as "do not enable remote mode").
func resolveRegistry(flag string) string {
	if flag != "" {
		return flag
	}
	if env := os.Getenv("VOILA_REGISTRY"); env != "" {
		return env
	}
	lc, err := cli.LoadLoginCreds()
	if err == nil && lc.Registry != "" {
		return lc.Registry
	}
	return ""
}

// resolveRegistryToken returns the bearer API key the CLI should authenticate
// to the registry with. Precedence:
//
//  1. $VOILA_REGISTRY_TOKEN, if set
//  2. ~/.config/voila/credentials (from `voila login`), if present
//  3. "" (no auth header; trusted-network default)
//
// Mirrors the $VOILA_REGISTRY_USER / $VOILA_REGISTRY_PASSWORD convention for
// `voila import`, keeping the secret out of shell history / process args.
// Passed to registry.NewClient via registry.WithToken.
func resolveRegistryToken() string {
	if tok := os.Getenv("VOILA_REGISTRY_TOKEN"); tok != "" {
		return tok
	}
	lc, err := cli.LoadLoginCreds()
	if err == nil {
		return lc.Token
	}
	return ""
}

// registryPuller adapts a *registry.Client to the imagestore.ManifestPuller
// interface. The imagestore package's ManifestPuller.GetImage signature
// matches registry.Client.GetImageManifest (HTTP fetch + protobuf unmarshal
// by the registry client); the indirection lets imagestore avoid importing
// internal/registry.
//
// The zero-value wrapper (with a nil *registry.Client) must NOT be passed
// as a non-nil imagestore.ManifestPuller — Go would wrap the nil-typed
// pointer into a non-nil interface, defeating imagestore.AutoPull's nil
// short-circuit.
type registryPuller struct {
	c *registry.Client
}

// GetImage satisfies imagestore.ManifestPuller.
func (p registryPuller) GetImage(ctx context.Context, ref string) (*voilapb.ImageManifest, error) {
	return p.c.GetImageManifest(ctx, ref)
}

// resolvePushConcurrency resolves the push upload fan-out. Precedence:
//  1. the -concurrency flag value, if it differs from defaultPushConcurrency
//     (i.e. the user set it explicitly)
//  2. $VOILA_PUSH_CONCURRENCY, if set and parseable
//  3. defaultPushConcurrency (64)
//
// The result is clamped to [minPushConcurrency, maxPushConcurrency]. A bad
// $VOILA_PUSH_CONCURRENCY falls back to the default (with no warning) so a
// stray env var cannot break push.
func resolvePushConcurrency(flag int) int {
	if flag != defaultPushConcurrency {
		return clampPushConcurrency(flag)
	}
	if v := os.Getenv("VOILA_PUSH_CONCURRENCY"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return clampPushConcurrency(n)
		}
	}
	return defaultPushConcurrency
}

// clampPushConcurrency bounds n to the documented [min, max] range so a
// typo (0, negative, or a goroutine storm) cannot starve or swamp the upload.
func clampPushConcurrency(n int) int {
	if n < minPushConcurrency {
		return minPushConcurrency
	}
	if n > maxPushConcurrency {
		return maxPushConcurrency
	}
	return n
}
