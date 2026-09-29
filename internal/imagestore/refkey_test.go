package imagestore

import (
	"testing"
)

func TestRefKey_AllowsSafeChars(t *testing.T) {
	got := RefKey("python:3.13")
	wantBase := "python_3.13"
	if len(got) < len(wantBase)+9 || got[:len(wantBase)] != wantBase || got[len(wantBase)] != '-' {
		t.Errorf("RefKey(%q) = %q, want base %q followed by '-' and 8 hex chars",
			"python:3.13", got, wantBase)
	}
	// Exactly 8 hex suffix chars after the dash.
	suffix := got[len(wantBase)+1:]
	if len(suffix) != 8 {
		t.Errorf("hash suffix len = %d, want 8 (got %q)", len(suffix), suffix)
	}
	for _, c := range suffix {
		ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
		if !ok {
			t.Errorf("non-hex char in suffix: %q (suffix=%q)", c, suffix)
		}
	}
}

func TestRefKey_KeepsAllowedChars(t *testing.T) {
	cases := map[string]string{
		"foo":              "foo",
		"a.b":              "a.b",
		"a-b":              "a-b",
		"a_b":              "a_b",
		"library/python:3": "library_python_3",
		"docker.io/img:v1": "docker.io_img_v1",
	}
	for ref, wantBase := range cases {
		got := RefKey(ref)
		if got[:len(wantBase)] != wantBase {
			t.Errorf("RefKey(%q): base got %q want %q (full=%q)", ref, got[:len(wantBase)], wantBase, got)
		}
		if got[len(wantBase)] != '-' {
			t.Errorf("RefKey(%q): missing '-' separator (full=%q)", ref, got)
		}
	}
}

// The spec calls out that "a/b" and "a_b" sanitize to the same base string and
// must still map to distinct keys because of the hash suffix.
func TestRefKey_CollisionAvoided(t *testing.T) {
	k1 := RefKey("a/b")
	k2 := RefKey("a_b")
	if k1 == k2 {
		t.Fatalf("collision: RefKey(\"a/b\")=%q == RefKey(\"a_b\")=%q", k1, k2)
	}
	// Both share the base "a_b-" but differ in the suffix.
	base := "a_b-"
	if k1[:len(base)] != base || k2[:len(base)] != base {
		t.Fatalf("bases differ: %q %q", k1, k2)
	}
	if k1[len(base):] == k2[len(base):] {
		t.Fatalf("hash suffixes collide for distinct refs: %q vs %q", k1, k2)
	}
}

func TestRefKey_Deterministic(t *testing.T) {
	if RefKey("foo:bar") != RefKey("foo:bar") {
		t.Fatal("RefKey is not deterministic")
	}
}
