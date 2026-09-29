package build

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/opencontainers/go-digest"
	"github.com/opencontainers/image-spec/specs-go/v1"
)

// ImageConfig holds the OCI image configuration voila build maintains across
// Dockerfile instructions.
type ImageConfig struct {
	img v1.Image
}

// NewImageConfig returns an empty image config (FROM scratch).
func NewImageConfig() *ImageConfig {
	return &ImageConfig{img: v1.Image{
		Config: v1.ImageConfig{
			Env:        []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
			WorkingDir: "/",
		},
		RootFS: v1.RootFS{Type: "layers", DiffIDs: []digest.Digest{}},
	}}
}

// FromOCI unmarshals an existing OCI image config blob.
func FromOCI(raw []byte) (*ImageConfig, error) {
	var img v1.Image
	if err := json.Unmarshal(raw, &img); err != nil {
		return nil, fmt.Errorf("build: parse image config: %w", err)
	}
	return &ImageConfig{img: img}, nil
}

// Marshal returns the JSON bytes to store as a config chunk.
func (c *ImageConfig) Marshal() ([]byte, error) {
	return json.Marshal(c.img)
}

// Config returns the underlying OCI config for mutation.
func (c *ImageConfig) Config() *v1.ImageConfig {
	return &c.img.Config
}

// SetEnv merges environment variables (KEY=val).
func (c *ImageConfig) SetEnv(vars map[string]string) {
	for k, v := range vars {
		c.setEnv(k, v)
	}
}

func (c *ImageConfig) setEnv(key, val string) {
	prefix := key + "="
	for i, e := range c.img.Config.Env {
		if len(e) >= len(prefix) && e[:len(prefix)] == prefix {
			c.img.Config.Env[i] = prefix + val
			return
		}
	}
	c.img.Config.Env = append(c.img.Config.Env, prefix+val)
}

// ExpandEnv substitutes $VAR and ${VAR} in s using build args + image env.
func ExpandEnv(s string, args map[string]string, cfg *ImageConfig) string {
	env := map[string]string{}
	for k, v := range args {
		env[k] = v
	}
	for _, e := range cfg.Config().Env {
		if key, val, ok := splitEnv(e); ok {
			env[key] = val
		}
	}
	return osExpand(s, env)
}

func splitEnv(e string) (key, val string, ok bool) {
	i := stringsIndexByte(e, '=')
	if i < 0 {
		return "", "", false
	}
	return e[:i], e[i+1:], true
}

func stringsIndexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func osExpand(s string, env map[string]string) string {
	var b stringsBuilder
	i := 0
	for i < len(s) {
		if s[i] != '$' {
			b.WriteByte(s[i])
			i++
			continue
		}
		if i+1 >= len(s) {
			b.WriteByte('$')
			break
		}
		if s[i+1] == '$' {
			b.WriteByte('$')
			i += 2
			continue
		}
		if s[i+1] == '{' {
			j := i + 2
			for j < len(s) && s[j] != '}' {
				j++
			}
			if j < len(s) {
				key := s[i+2 : j]
				if v, ok := env[key]; ok {
					b.WriteString(v)
				}
				i = j + 1
				continue
			}
		}
		j := i + 1
		for j < len(s) && isEnvNameChar(s[j]) {
			j++
		}
		key := s[i+1 : j]
		if v, ok := env[key]; ok {
			b.WriteString(v)
		}
		i = j
	}
	return b.String()
}

func isEnvNameChar(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

type stringsBuilder struct {
	buf []byte
}

func (b *stringsBuilder) WriteByte(c byte) error {
	b.buf = append(b.buf, c)
	return nil
}

func (b *stringsBuilder) WriteString(s string) {
	b.buf = append(b.buf, s...)
}

func (b *stringsBuilder) String() string {
	return string(b.buf)
}

// SetLabels merges labels.
func (c *ImageConfig) SetLabels(labels map[string]string) {
	if c.img.Config.Labels == nil {
		c.img.Config.Labels = map[string]string{}
	}
	for k, v := range labels {
		c.img.Config.Labels[k] = v
	}
}

// SetExposedPorts records EXPOSE directives.
func (c *ImageConfig) SetExposedPorts(ports []string) {
	if c.img.Config.ExposedPorts == nil {
		c.img.Config.ExposedPorts = map[string]struct{}{}
	}
	for _, p := range ports {
		c.img.Config.ExposedPorts[p] = struct{}{}
	}
}

// SetVolumes records VOLUME directives.
func (c *ImageConfig) SetVolumes(paths []string) {
	if c.img.Config.Volumes == nil {
		c.img.Config.Volumes = map[string]struct{}{}
	}
	for _, p := range paths {
		c.img.Config.Volumes[p] = struct{}{}
	}
}

// SetStopSignal records STOPSIGNAL.
func (c *ImageConfig) SetStopSignal(sig string) {
	c.img.Config.StopSignal = sig
}

// Digest computes sha256 of the config JSON for image identity.
func (c *ImageConfig) Digest() ([]byte, error) {
	raw, err := c.Marshal()
	if err != nil {
		return nil, err
	}
	d := digest.FromBytes(raw)
	return []byte(d.String()), nil
}

// Architecture fields for OCI completeness.
func (c *ImageConfig) SetPlatform(osName, arch string) {
	c.img.OS = osName
	c.img.Architecture = arch
}

// EnsureCreated sets Created timestamp if unset.
func (c *ImageConfig) EnsureCreated() {
	if c.img.Created == nil {
		now := time.Now()
		c.img.Created = &now
	}
}
