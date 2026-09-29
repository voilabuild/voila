// Package runtime builds OCI runtime-spec bundles and drives the runc binary
// (or any compatible runner) in the foreground. See plan §7.
package runtime

import (
	"encoding/json"
	"fmt"

	"github.com/opencontainers/image-spec/specs-go/v1"
)

// ImageConfig is the subset of the OCI image config voila needs at run time.
// It mirrors the process-default fields of v1.ImageConfig (env, entrypoint,
// cmd, working dir).
type ImageConfig struct {
	Env        []string
	Entrypoint []string
	Cmd        []string
	WorkingDir string
}

// ParseImageConfig unmarshals raw OCI image-config JSON (a v1.Image blob, as
// stored by the ingester as the ImageManifest.config_chunk) and projects it
// onto ImageConfig. Only the process-default fields are retained; the rest of
// the OCI config (history, rootfs digests, exposed ports, labels, …) is
// irrelevant at run time and dropped.
func ParseImageConfig(raw []byte) (*ImageConfig, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("runtime: empty image config")
	}
	var img v1.Image
	if err := json.Unmarshal(raw, &img); err != nil {
		return nil, fmt.Errorf("runtime: parse image config: %w", err)
	}
	c := &ImageConfig{
		Env:        cloneStrings(img.Config.Env),
		Entrypoint: cloneStrings(img.Config.Entrypoint),
		Cmd:        cloneStrings(img.Config.Cmd),
		WorkingDir: img.Config.WorkingDir,
	}
	return c, nil
}

// Argv merges docker-style: entrypoint + (override if non-empty else cmd).
// A nil/empty override falls back to cmd, mirroring `docker run <img> <cmd>`
// semantics where omitting argv uses the image's Cmd. The returned slice may
// be empty when both entrypoint and cmd are empty (the caller surfaces an
// error in that case, not Argv).
func (c *ImageConfig) Argv(override []string) []string {
	out := make([]string, 0, len(c.Entrypoint)+len(override)+len(c.Cmd))
	out = append(out, c.Entrypoint...)
	if len(override) > 0 {
		out = append(out, override...)
	} else {
		out = append(out, c.Cmd...)
	}
	return out
}

// defaultPath is injected by Environ when no PATH entry is present.
const defaultPath = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

// Environ returns Env, guaranteeing a PATH entry. When the image config does
// not supply PATH, the standard docker-style default is appended. Existing
// PATH entries (however exotic) are left untouched.
func (c *ImageConfig) Environ() []string {
	out := make([]string, 0, len(c.Env)+1)
	out = append(out, c.Env...)
	if !hasPath(c.Env) {
		out = append(out, defaultPath)
	}
	return out
}

// Cwd returns WorkingDir or "/" when unset, so the OCI process cwd is always
// absolute and non-empty as required by the runtime spec.
func (c *ImageConfig) Cwd() string {
	if c.WorkingDir == "" {
		return "/"
	}
	return c.WorkingDir
}

// hasPath reports whether env already contains a "PATH=..." entry (case
// sensitive on the key, matching the kernel and runc).
func hasPath(env []string) bool {
	for _, e := range env {
		if len(e) >= 5 && e[:5] == "PATH=" {
			return true
		}
	}
	return false
}

// cloneStrings returns a defensive copy of in so callers cannot mutate the
// image config's slices through the returned value.
func cloneStrings(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	out := make([]string, len(in))
	copy(out, in)
	return out
}
