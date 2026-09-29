package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// TestBuildSpec_Golden checks every invariant called out in the task spec's
// BuildSpec bullet list: root readonly + path, all 8 mounts with the right
// types/destinations, 5 namespaces, no seccomp, resources only when set,
// hostname.
func TestBuildSpec_Golden(t *testing.T) {
	o := BundleOpts{
		RootfsPath: "/tmp/voila-rootfs",
		Args:       []string{"/bin/sh", "-c", "echo hi"},
		Env:        []string{"PATH=/usr/bin", "FOO=bar"},
		Cwd:        "/srv",
		Hostname:   "voila",
	}
	spec, err := BuildSpec(o)
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}

	if spec.Version != specs.Version {
		t.Errorf("OciVersion = %q, want %q", spec.Version, specs.Version)
	}
	if spec.Root == nil {
		t.Fatal("Root is nil")
	}
	if spec.Root.Path != "/tmp/voila-rootfs" {
		t.Errorf("Root.Path = %q, want /tmp/voila-rootfs", spec.Root.Path)
	}
	if !spec.Root.Readonly {
		t.Error("Root.Readonly = false, want true")
	}
	if spec.Hostname != "voila" {
		t.Errorf("Hostname = %q, want voila", spec.Hostname)
	}

	// Process.
	if spec.Process == nil {
		t.Fatal("Process is nil")
	}
	if spec.Process.Terminal {
		t.Error("Terminal = true, want false")
	}
	if !equalStrings(spec.Process.Args, o.Args) {
		t.Errorf("Process.Args = %v, want %v", spec.Process.Args, o.Args)
	}
	if !equalStrings(spec.Process.Env, o.Env) {
		t.Errorf("Process.Env = %v, want %v", spec.Process.Env, o.Env)
	}
	if spec.Process.Cwd != "/srv" {
		t.Errorf("Process.Cwd = %q, want /srv", spec.Process.Cwd)
	}
	if !spec.Process.NoNewPrivileges {
		t.Error("NoNewPrivileges = false, want true")
	}
	if spec.Process.Capabilities == nil {
		t.Fatal("Capabilities is nil")
	}
	for _, set := range [][]string{
		spec.Process.Capabilities.Bounding,
		spec.Process.Capabilities.Effective,
		spec.Process.Capabilities.Permitted,
	} {
		if !equalStrings(set, defaultCaps) {
			t.Errorf("cap set = %v, want %v", set, defaultCaps)
		}
	}

	// Mounts: all 8 present with right types/destinations.
	wantMounts := []struct {
		dst, typ string
	}{
		{"/proc", "proc"},
		{"/dev", "tmpfs"},
		{"/dev/pts", "devpts"},
		{"/dev/shm", "tmpfs"},
		{"/dev/mqueue", "mqueue"},
		{"/sys", "sysfs"},
		{"/tmp", "tmpfs"},
		{"/var/tmp", "tmpfs"},
	}
	if len(spec.Mounts) != len(wantMounts) {
		t.Fatalf("len(Mounts) = %d, want %d", len(spec.Mounts), len(wantMounts))
	}
	for i, want := range wantMounts {
		m := spec.Mounts[i]
		if m.Destination != want.dst {
			t.Errorf("Mount[%d].Destination = %q, want %q", i, m.Destination, want.dst)
		}
		if m.Type != want.typ {
			t.Errorf("Mount[%d].Type = %q, want %q", i, m.Type, want.typ)
		}
	}
	// /dev tmpfs must be RO? No, the spec: mode=755,size=65536k,strictatime.
	if devM := spec.Mounts[1]; devM.Destination != "/dev" {
		t.Errorf("/dev mount = %q", devM.Destination)
	}
	// sysfs ro
	for _, m := range spec.Mounts {
		if m.Destination == "/sys" {
			if !contains(m.Options, "ro") {
				t.Errorf("/sys options = %v, want ro", m.Options)
			}
		}
	}

	// 5 namespaces, no seccomp.
	if spec.Linux == nil {
		t.Fatal("Linux is nil")
	}
	if len(spec.Linux.Namespaces) != 5 {
		t.Fatalf("len(Namespaces) = %d, want 5", len(spec.Linux.Namespaces))
	}
	wantNS := []specs.LinuxNamespaceType{
		specs.PIDNamespace,
		specs.IPCNamespace,
		specs.UTSNamespace,
		specs.MountNamespace,
		specs.NetworkNamespace,
	}
	for i, want := range wantNS {
		if spec.Linux.Namespaces[i].Type != want {
			t.Errorf("Namespace[%d].Type = %q, want %q", i, spec.Linux.Namespaces[i].Type, want)
		}
	}
	if spec.Linux.Seccomp != nil {
		t.Error("Seccomp is non-nil; v0.1 leaves it unset so runc applies none")
	}
	// No user namespace.
	for _, ns := range spec.Linux.Namespaces {
		if ns.Type == specs.UserNamespace {
			t.Error("UserNamespace present; v0.1 runs root-only")
		}
	}

	// MaskedPaths / ReadonlyPaths populated and non-empty.
	if len(spec.Linux.MaskedPaths) == 0 {
		t.Error("MaskedPaths is empty")
	}
	if len(spec.Linux.ReadonlyPaths) == 0 {
		t.Error("ReadonlyPaths is empty")
	}
	if !contains(spec.Linux.MaskedPaths, "/proc/kcore") {
		t.Errorf("MaskedPaths missing /proc/kcore: %v", spec.Linux.MaskedPaths)
	}

	// Resources nil when no limits set.
	if spec.Linux.Resources != nil {
		t.Errorf("Resources non-nil with no limits: %+v", spec.Linux.Resources)
	}
}

// TestBuildSpec_Resources verifies limits only when set.
func TestBuildSpec_Resources(t *testing.T) {
	o := BundleOpts{
		RootfsPath:       "/rootfs",
		Args:             []string{"sh"},
		MemoryLimitBytes: 256 * 1024 * 1024,
		CPUQuotaPercent:  200,
	}
	spec, err := BuildSpec(o)
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}
	if spec.Linux.Resources == nil {
		t.Fatal("Resources is nil")
	}
	if spec.Linux.Resources.Memory == nil || spec.Linux.Resources.Memory.Limit == nil {
		t.Fatal("Memory limit missing")
	}
	if got := *spec.Linux.Resources.Memory.Limit; got != o.MemoryLimitBytes {
		t.Errorf("Memory.Limit = %d, want %d", got, o.MemoryLimitBytes)
	}
	if spec.Linux.Resources.CPU == nil || spec.Linux.Resources.CPU.Quota == nil || spec.Linux.Resources.CPU.Period == nil {
		t.Fatal("CPU quota/period missing")
	}
	if got := *spec.Linux.Resources.CPU.Quota; got != int64(o.CPUQuotaPercent)*1000 {
		t.Errorf("CPU.Quota = %d, want %d", got, int64(o.CPUQuotaPercent)*1000)
	}
	if got := *spec.Linux.Resources.CPU.Period; got != 100000 {
		t.Errorf("CPU.Period = %d, want 100000", got)
	}
}

// TestBuildSpec_DefaultHostname verifies Hostname defaults to "voila".
func TestBuildSpec_DefaultHostname(t *testing.T) {
	spec, err := BuildSpec(BundleOpts{RootfsPath: "/rootfs", Args: []string{"sh"}})
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}
	if spec.Hostname != "voila" {
		t.Errorf("Hostname = %q, want voila", spec.Hostname)
	}
}

// TestBuildSpec_Errors covers invalid-input rejection.
func TestBuildSpec_Errors(t *testing.T) {
	if _, err := BuildSpec(BundleOpts{}); err == nil {
		t.Fatal("expected error for empty RootfsPath")
	}
	if _, err := BuildSpec(BundleOpts{RootfsPath: "rel/path", Args: []string{"sh"}}); err == nil {
		t.Fatal("expected error for relative RootfsPath")
	}
	if _, err := BuildSpec(BundleOpts{RootfsPath: "/abs", Args: nil}); err == nil {
		t.Fatal("expected error for empty Args")
	}
}

// TestBuildSpec_Writable confirms Writable flips Root.Readonly off (the
// launcher stacks a writable overlay over the RO FUSE lower when it opts in).
func TestBuildSpec_Writable(t *testing.T) {
	o := BundleOpts{
		RootfsPath: "/tmp/voila-rootfs",
		Args:       []string{"/bin/sh", "-c", "echo hi"},
		Writable:   true,
	}
	spec, err := BuildSpec(o)
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}
	if spec.Root.Readonly {
		t.Error("Root.Readonly = true, want false when Writable is set")
	}
	// Default (Writable false) stays read-only — the v0.1 contract for
	// callers that don't opt in.
	specRO, err := BuildSpec(BundleOpts{RootfsPath: "/tmp/voila-rootfs", Args: []string{"sh"}})
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}
	if !specRO.Root.Readonly {
		t.Error("Root.Readonly = false, want true when Writable is unset")
	}
}

// TestWriteBundle_RoundTrip writes a spec, reads it back, and confirms it
// round-trips into a specs.Spec.
func TestWriteBundle_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	bundleDir := filepath.Join(dir, "bundle")
	spec, err := BuildSpec(BundleOpts{
		RootfsPath: "/var/voila/rootfs",
		Args:       []string{"/bin/echo", "hi"},
		Env:        []string{"PATH=/usr/bin"},
		Cwd:        "/",
	})
	if err != nil {
		t.Fatalf("BuildSpec: %v", err)
	}
	if err := WriteBundle(bundleDir, spec); err != nil {
		t.Fatalf("WriteBundle: %v", err)
	}
	path := filepath.Join(bundleDir, "config.json")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("config.json perm = %o, want 600", info.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got specs.Spec
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Version != spec.Version {
		t.Errorf("Version = %q, want %q", got.Version, spec.Version)
	}
	if got.Root == nil || got.Root.Path != spec.Root.Path {
		t.Errorf("Root mismatch: %+v", got.Root)
	}
	if !equalStrings(got.Process.Args, spec.Process.Args) {
		t.Errorf("Args mismatch: %v", got.Process.Args)
	}
	// Mounts round-trip.
	if len(got.Mounts) != len(spec.Mounts) {
		t.Errorf("Mounts len = %d, want %d", len(got.Mounts), len(spec.Mounts))
	}
}

// TestWriteBundle_NilSpec rejects nil spec.
func TestWriteBundle_NilSpec(t *testing.T) {
	if err := WriteBundle(t.TempDir(), nil); err == nil {
		t.Fatal("expected error for nil spec")
	}
	if err := WriteBundle("", &specs.Spec{}); err == nil {
		t.Fatal("expected error for empty bundleDir")
	}
}

// contains reports whether s is a substring match in slice.
func contains(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}
