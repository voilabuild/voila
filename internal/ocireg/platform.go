package ocireg

import (
	"strings"

	v1 "github.com/opencontainers/image-spec/specs-go/v1"
)

// platformString renders an OCI platform descriptor as os/arch[/variant].
func platformString(p *v1.Platform) string {
	if p == nil {
		return ""
	}
	if p.Variant != "" {
		return p.OS + "/" + p.Architecture + "/" + p.Variant
	}
	return p.OS + "/" + p.Architecture
}

// parsePlatform splits an "os/arch[/variant]" selector into its parts. An
// empty arch means the selector was empty (the caller falls back to the
// runtime platform).
func parsePlatform(s string) (os, arch, variant string) {
	parts := strings.SplitN(s, "/", 3)
	if len(parts) >= 1 {
		os = parts[0]
	}
	if len(parts) >= 2 {
		arch = parts[1]
	}
	if len(parts) >= 3 {
		variant = parts[2]
	}
	return
}

// platformMatches reports whether a descriptor's platform satisfies the
// requested one. OS and Architecture must match exactly; the Variant matches
// if either side is unspecified (a request for "linux/arm64" matches a
// "linux/arm64/v8" manifest) or if they are equal. This mirrors how
// containerd/Docker resolve multi-arch images: the variant is optional on the
// request side, so a bare "linux/arm64" host picks up the arm64/v8 entry.
func platformMatches(want, got *v1.Platform) bool {
	if want == nil || got == nil {
		return false
	}
	if want.OS != got.OS || want.Architecture != got.Architecture {
		return false
	}
	if want.Variant != "" && got.Variant != "" && want.Variant != got.Variant {
		return false
	}
	return true
}

// defaultVariant returns the conventional default variant for an architecture
// (arm64 → v8, arm → v7) used to break ties when a variant-less request
// matches several descriptors. Amd64 / 386 / riscv64 etc. have no variant.
func defaultVariant(arch string) string {
	switch arch {
	case "arm64":
		return "v8"
	case "arm":
		return "v7"
	default:
		return ""
	}
}
