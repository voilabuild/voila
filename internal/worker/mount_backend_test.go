package worker

import "testing"

func TestResolveMountBackend_EnvOverride(t *testing.T) {
	probeUnused := func() (bool, string) {
		t.Fatal("probe should not run for an explicit fuse/erofs override")
		return false, ""
	}
	cases := []struct {
		env  string
		want string
	}{
		{env: "fuse", want: backendFUSE},
		{env: "FUSE", want: backendFUSE},
		{env: "erofs", want: backendEROFS},
		{env: "EROFS", want: backendEROFS},
		{env: " erofs ", want: backendEROFS},
	}
	for _, tc := range cases {
		got, _ := resolveMountBackendWith(tc.env, probeUnused)
		if got != tc.want {
			t.Errorf("env %q: got %q, want %q", tc.env, got, tc.want)
		}
	}
}

func TestResolveMountBackend_AutoProbe(t *testing.T) {
	got, why := resolveMountBackendWith("", func() (bool, string) {
		return true, "erofs+nbd ready"
	})
	if got != backendEROFS || why != "erofs+nbd ready" {
		t.Fatalf("auto ready: got %q (%q), want erofs", got, why)
	}

	got, why = resolveMountBackendWith("auto", func() (bool, string) {
		return false, "no usable /dev/nbd*"
	})
	if got != backendFUSE || why != "no usable /dev/nbd*" {
		t.Fatalf("auto missing nbd: got %q (%q), want fuse", got, why)
	}

	got, why = resolveMountBackendWith("weird", func() (bool, string) {
		t.Fatal("probe should not run for unknown env")
		return false, ""
	})
	if got != backendFUSE {
		t.Fatalf("unknown env: got %q, want fuse", got)
	}
	if why == "" {
		t.Fatal("unknown env should explain the fallback")
	}
}

func TestKernelReleaseAtLeast(t *testing.T) {
	cases := []struct {
		rel  string
		want bool
	}{
		{rel: "5.15.0-91-generic", want: true},
		{rel: "5.15.0", want: true},
		{rel: "6.1.0-18-amd64", want: true},
		{rel: "6.8.0-40-generic", want: true},
		{rel: "5.14.0-427.el9.x86_64", want: false},
		{rel: "5.10.0-8-amd64", want: false},
		{rel: "4.19.0", want: false},
		{rel: "", want: false},
		{rel: "not-a-version", want: false},
	}
	for _, tc := range cases {
		if got := kernelReleaseAtLeast(tc.rel, 5, 15); got != tc.want {
			t.Errorf("kernelReleaseAtLeast(%q, 5, 15) = %v, want %v", tc.rel, got, tc.want)
		}
	}
}

func TestFilesystemsHas(t *testing.T) {
	data := "nodev\tsysfs\nnodev\tfuse\n\terofs\nnodev\tbpf\n"
	if !filesystemsHas(data, "erofs") {
		t.Fatal("expected erofs listed")
	}
	if filesystemsHas(data, "nbd") {
		t.Fatal("nbd is not a filesystem")
	}
	if filesystemsHas("nodev\tfuse\n", "erofs") {
		t.Fatal("erofs must not match a listing that only has fuse")
	}
}
