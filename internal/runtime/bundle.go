package runtime

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// BundleOpts carries the inputs to BuildSpec. The bundle is consumed by runc
// (or any compatible runtime) via the OCI runtime-spec config.json.
type BundleOpts struct {
	// RootfsPath is the absolute path to the (FUSE) rootfs mountpoint inside
	// the bundle. It must exist; runc pivots into it.
	RootfsPath string
	// Args is the already-merged process argv (Argv output).
	Args []string
	// Env is the process environment (Environ output).
	Env []string
	// Cwd is the process working directory inside the rootfs.
	Cwd string
	// Hostname defaults to "voila" when empty.
	Hostname string
	// Terminal is plumbed for v0.1 but only false is exercised (no console
	// socket / tty support yet — plan §10).
	Terminal bool
	// Writable makes the rootfs writable (Root.Readonly = false). The
	// launcher stacks a writable overlay over the read-only FUSE lower so
	// the container can write to its rootfs (apt install, chmod, an image
	// entrypoint that initializes a data dir in-place, …) while the image
	// stays content-addressed. The upper layer is torn down with the
	// context, so nothing persists across a run — same ephemeral semantics
	// as the tmpfs upper surface, just covering the whole rootfs. Default
	// false preserves the v0.1 read-only contract for callers that don't
	// opt in.
	Writable bool
	// HostNetwork omits the network namespace so the container shares the
	// host network stack. Used for `voila build` RUN steps (apt-get, curl).
	HostNetwork bool
	// MemoryLimitBytes is the cgroup-v2 memory.max. 0 = no limit.
	MemoryLimitBytes int64
	// CPUQuotaPercent is the cpu quota in core-percent. 100 = one core,
	// expressed as quota=100000, period=100000 (usec). 0 = no limit.
	CPUQuotaPercent int
}

// defaultCaps is Docker's default capability set, applied verbatim to the
// bounding, effective, and permitted sets. runc spec's minimal trio
// (AUDIT_WRITE/KILL/NET_BIND_SERVICE) turned out too narrow for real images:
// entrypoints that drop privileges (su/gosu in postgres, mysql, …) need
// SETUID/SETGID/CHOWN and friends. Docker's set is the de facto contract for
// "docker save X && voila run X works".
var defaultCaps = []string{
	"CAP_AUDIT_WRITE",
	"CAP_CHOWN",
	"CAP_DAC_OVERRIDE",
	"CAP_FOWNER",
	"CAP_FSETID",
	"CAP_KILL",
	"CAP_MKNOD",
	"CAP_NET_BIND_SERVICE",
	"CAP_NET_RAW",
	"CAP_SETFCAP",
	"CAP_SETGID",
	"CAP_SETPCAP",
	"CAP_SETUID",
	"CAP_SYS_CHROOT",
}

// defaultMounts replicates `runc spec`'s default mount table plus the
// ephemeral tmpfs surface voila supplies (plan §7.3). Order is preserved so
// tests can golden-check.
func defaultMounts() []specs.Mount {
	return []specs.Mount{
		{
			Destination: "/proc",
			Type:        "proc",
			Source:      "proc",
		},
		{
			Destination: "/dev",
			Type:        "tmpfs",
			Source:      "tmpfs",
			Options:     []string{"mode=755", "size=65536k", "strictatime"},
		},
		{
			Destination: "/dev/pts",
			Type:        "devpts",
			Source:      "devpts",
			Options:     []string{"newinstance", "ptmxmode=0666", "mode=0620", "gid=5"},
		},
		{
			Destination: "/dev/shm",
			Type:        "tmpfs",
			Source:      "shm",
			Options:     []string{"mode=1777", "size=65536k"},
		},
		{
			Destination: "/dev/mqueue",
			Type:        "mqueue",
			Source:      "mqueue",
		},
		{
			Destination: "/sys",
			Type:        "sysfs",
			Source:      "sysfs",
			Options:     []string{"ro"},
		},
		{
			Destination: "/tmp",
			Type:        "tmpfs",
			Source:      "tmpfs",
			Options:     []string{"rw", "nosuid", "nodev", "mode=1777"},
		},
		{
			Destination: "/var/tmp",
			Type:        "tmpfs",
			Source:      "tmpfs",
			Options:     []string{"rw", "nosuid", "nodev", "mode=1777"},
		},
	}
}

// defaultNamespaces is pid, ipc, uts, mount, network (private — no config,
// gives lo only). No user namespace in v0.1 (root required; plan §7 / §10).
// When hostNetwork is true the network namespace is omitted so the container
// shares the host stack (build RUN steps).
func defaultNamespaces(hostNetwork bool) []specs.LinuxNamespace {
	ns := []specs.LinuxNamespace{
		{Type: specs.PIDNamespace},
		{Type: specs.IPCNamespace},
		{Type: specs.UTSNamespace},
		{Type: specs.MountNamespace},
	}
	if !hostNetwork {
		ns = append(ns, specs.LinuxNamespace{Type: specs.NetworkNamespace})
	}
	return ns
}

// defaultMaskedPaths / defaultReadonlyPaths copy runc spec defaults.
var defaultMaskedPaths = []string{
	"/proc/asound",
	"/proc/acpi",
	"/proc/kcore",
	"/proc/keys",
	"/proc/latency_stats",
	"/proc/timer_list",
	"/proc/timer_stats",
	"/proc/sched_debug",
	"/proc/scsi",
	"/sys/firmware",
	"/sys/devices/virtual/powercap",
}

var defaultReadonlyPaths = []string{
	"/proc/bus",
	"/proc/fs",
	"/proc/irq",
	"/proc/sys",
	"/proc/sysrq-trigger",
}

// defaultProcess builds the OCI specs.Process with the runtime defaults voila
// applies to every container process (main and exec): the runc-default
// capability triple, RLIMIT_NOFILE 1024, no_new_privileges, and the caller's
// args/env/cwd. terminal is plumbed so the main process can carry a future
// tty flag without exec processes inheriting it (v0.1 exec is always
// non-terminal).
func defaultProcess(terminal bool, args, env []string, cwd string) *specs.Process {
	return &specs.Process{
		Terminal: terminal,
		Args:     append([]string(nil), args...),
		Env:      append([]string(nil), env...),
		Cwd:      cwd,
		Capabilities: &specs.LinuxCapabilities{
			Bounding:  append([]string(nil), defaultCaps...),
			Effective: append([]string(nil), defaultCaps...),
			Permitted: append([]string(nil), defaultCaps...),
		},
		Rlimits: []specs.POSIXRlimit{
			{Type: "RLIMIT_NOFILE", Hard: 1024, Soft: 1024},
		},
		NoNewPrivileges: true,
	}
}

// BuildProcess returns the OCI specs.Process used by an additional `runc exec`
// invocation, with the same default capabilities, rlimits, and
// no_new_privileges settings BuildSpec applies to the main process. The
// process is non-terminal (v0.1 does not wire console sockets for exec).
//
// It is a package-level entry point, separate from BuildSpec, so callers
// driving `runc exec` (the worker's Linux Launcher) get a *specs.Process for
// ExecProcess without constructing a full *specs.Spec.
func BuildProcess(args, env []string, cwd string) *specs.Process {
	return defaultProcess(false, args, env, cwd)
}

// BuildSpec produces a *specs.Spec from o suitable for handing to runc. It
// does not write to disk; WriteBundle does. Returns an error if RootfsPath
// is not absolute (the OCI spec requires an absolute path).
func BuildSpec(o BundleOpts) (*specs.Spec, error) {
	if o.RootfsPath == "" {
		return nil, fmt.Errorf("runtime: BundleOpts.RootfsPath is required")
	}
	if !filepath.IsAbs(o.RootfsPath) {
		return nil, fmt.Errorf("runtime: RootfsPath must be absolute, got %q", o.RootfsPath)
	}
	if len(o.Args) == 0 {
		return nil, fmt.Errorf("runtime: BundleOpts.Args must be non-empty")
	}
	hostname := o.Hostname
	if hostname == "" {
		hostname = "voila"
	}

	linux := &specs.Linux{
		Namespaces:    defaultNamespaces(o.HostNetwork),
		MaskedPaths:   append([]string(nil), defaultMaskedPaths...),
		ReadonlyPaths: append([]string(nil), defaultReadonlyPaths...),
	}
	if o.MemoryLimitBytes > 0 || o.CPUQuotaPercent > 0 {
		linux.Resources = &specs.LinuxResources{}
		if o.MemoryLimitBytes > 0 {
			limit := o.MemoryLimitBytes
			linux.Resources.Memory = &specs.LinuxMemory{Limit: &limit}
		}
		if o.CPUQuotaPercent > 0 {
			// 100% = 1 core → quota=100000 usec in a 100000 usec period.
			quota := int64(o.CPUQuotaPercent) * 1000
			period := uint64(100000)
			linux.Resources.CPU = &specs.LinuxCPU{
				Quota:  &quota,
				Period: &period,
			}
		}
	}

	spec := &specs.Spec{
		Version:  specs.Version,
		Process:  defaultProcess(o.Terminal, o.Args, o.Env, o.Cwd),
		Root:     &specs.Root{Path: o.RootfsPath, Readonly: !o.Writable},
		Hostname: hostname,
		Mounts:   defaultMounts(),
		Linux:    linux,
	}
	return spec, nil
}

// WriteBundle writes spec marshaled to JSON at <bundleDir>/config.json with
// 0600 perms. The bundle directory is created if it does not exist.
func WriteBundle(bundleDir string, spec *specs.Spec) error {
	if bundleDir == "" {
		return fmt.Errorf("runtime: bundleDir is required")
	}
	if spec == nil {
		return fmt.Errorf("runtime: spec is required")
	}
	if err := os.MkdirAll(bundleDir, 0o755); err != nil {
		return fmt.Errorf("runtime: mkdir bundle: %w", err)
	}
	data, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		return fmt.Errorf("runtime: marshal spec: %w", err)
	}
	path := filepath.Join(bundleDir, "config.json")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return fmt.Errorf("runtime: write %s: %w", path, err)
	}
	return nil
}
