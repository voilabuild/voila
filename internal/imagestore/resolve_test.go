package imagestore

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"

	"voila/internal/chunkstore"
	voilapb "voila/internal/proto"
)

// seedImage writes a minimal-but-valid ImageManifest pb + images.db row for
// ref, with ImageDigest = 32 copies of digestByte (distinct per image so
// digest-prefix cases can address them). Returns the hex digest.
func seedImage(t *testing.T, s *Store, ref string, digestByte byte) string {
	t.Helper()
	var digest [32]byte
	for i := range digest {
		digest[i] = digestByte
	}
	im := &voilapb.ImageManifest{
		ImageRef:                ref,
		MergedRootManifestChunk: digest[:],
	}
	if err := s.WriteManifestPB(ref, im); err != nil {
		t.Fatalf("seed %s: WriteManifestPB: %v", ref, err)
	}
	if err := s.Upsert(Record{
		Ref:                ref,
		ImageDigest:        digest[:],
		MergedRootManifest: digest[:],
	}); err != nil {
		t.Fatalf("seed %s: Upsert: %v", ref, err)
	}
	return strings.ToLower(hex.EncodeToString(digest[:]))
}

// TestResolve_NormalizesShortRefs is the regression suite for the
// ingest-vs-resolve ref mismatch: `voila import python:3.13` stores the row
// under the canonical `registry-1.docker.io/library/python:3.13`, so every
// lookup must apply the same normalization (ocireg.Canonical) to the user's
// query before matching.
func TestResolve_NormalizesShortRefs(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	seedImage(t, s, "registry-1.docker.io/library/alpine:latest", 0x01)
	seedImage(t, s, "registry-1.docker.io/library/python:3.13", 0x02)
	seedImage(t, s, "quay.io/coreos/etcd:v3.5", 0x03)

	cases := []struct {
		name, query, wantRef string
		wantErr              string
	}{
		// Short official-image refs.
		{"bare official image defaults to latest", "alpine", "registry-1.docker.io/library/alpine:latest", ""},
		{"official image with tag", "python:3.13", "registry-1.docker.io/library/python:3.13", ""},
		{"docker.io alias", "docker.io/library/python:3.13", "registry-1.docker.io/library/python:3.13", ""},
		{"fully qualified exact", "registry-1.docker.io/library/alpine:latest", "registry-1.docker.io/library/alpine:latest", ""},
		{"org ref fully qualified", "quay.io/coreos/etcd:v3.5", "quay.io/coreos/etcd:v3.5", ""},
		{"no match", "nosuch:image", "", `no image matching "nosuch:image"`},
		{"digest-prefix-shaped miss", "12345678", "", `no image matching "12345678"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			im, rootChunk, err := Resolve(s, tc.query)
			if tc.wantRef == "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("Resolve(%q) error = %v, want containing %q", tc.query, err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Resolve(%q): %v", tc.query, err)
			}
			if got := im.GetImageRef(); got != tc.wantRef {
				t.Errorf("resolved ref = %q, want %q", got, tc.wantRef)
			}
			if len(rootChunk) != len(chunkstore.ChunkID{}) || rootChunk[0] != rootChunk[31] {
				t.Errorf("rootChunk = %v, want the seeded 32-byte pattern", rootChunk)
			}
		})
	}
}

// TestResolve_DigestPrefixStillWorks pins the digest-prefix rules that must
// keep working now that normalized-ref matching sits between exact and
// prefix matching.
func TestResolve_DigestPrefixStillWorks(t *testing.T) {
	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	digA := seedImage(t, s, "registry-1.docker.io/library/a:1", 0xaa)
	digB := seedImage(t, s, "registry-1.docker.io/library/b:1", 0xbb)

	cases := []struct {
		name, query, wantRef string
		wantErr              string
	}{
		{"short unique prefix", digA[:8], "registry-1.docker.io/library/a:1", ""},
		{"sha256-schemed full digest", "sha256:" + digB, "registry-1.docker.io/library/b:1", ""},
		{"unknown prefix", "12345678", "", `no image matching "12345678"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			im, _, err := Resolve(s, tc.query)
			if tc.wantRef != "" {
				if err != nil {
					t.Fatalf("Resolve(%q): %v", tc.query, err)
				}
				if got := im.GetImageRef(); got != tc.wantRef {
					t.Errorf("resolved ref = %q, want %q", got, tc.wantRef)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("Resolve(%q) error = %v, want containing %q", tc.query, err, tc.wantErr)
			}
		})
	}

	// Ambiguous prefix: both images seeded with the same leading nibble.
	root2 := t.TempDir()
	s2, err := Open(root2)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	dup := seedImage(t, s2, "dup:x", 0xcc)
	_ = seedImage(t, s2, "dup:y", 0xcd) // shares "c" nibble + differs later
	_, _, err = Resolve(s2, dup[:1])
	if err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("ambiguous-prefix Resolve error = %v, want ambiguous", err)
	}
}

// pullerFunc adapts a func to ManifestPuller for the PullManifest fallback
// test below.
type pullerFunc func(ctx context.Context, ref string) (*voilapb.ImageManifest, error)

func (f pullerFunc) GetImage(ctx context.Context, ref string) (*voilapb.ImageManifest, error) {
	return f(ctx, ref)
}

// TestPullManifest_CanonicalFallback verifies the remote-pull half of the
// fix: a fetch by short ref retries with the canonical form (what push
// uploaded), while a verbatim-pushed ref still resolves on the first try.
func TestPullManifest_CanonicalFallback(t *testing.T) {
	canon := "registry-1.docker.io/library/python:3.13"
	verbatim := "auto:v1"

	fetched := []string{}
	puller := pullerFunc(func(_ context.Context, ref string) (*voilapb.ImageManifest, error) {
		fetched = append(fetched, ref)
		switch ref {
		case canon:
			return &voilapb.ImageManifest{ImageRef: canon, ImageDigest: []byte(canon), MergedRootManifestChunk: make([]byte, 32)}, nil
		case verbatim:
			return &voilapb.ImageManifest{ImageRef: verbatim, ImageDigest: []byte(verbatim), MergedRootManifestChunk: make([]byte, 32)}, nil
		default:
			return nil, fmt.Errorf("fake miss %q", ref)
		}
	})

	root := t.TempDir()
	s, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	// Short ref misses, canonical retry hits, manifest persists under the
	// canonical ref the registry reported.
	fetched = nil
	im, err := PullManifest(context.Background(), s, puller, "python:3.13")
	if err != nil {
		t.Fatalf("PullManifest(python:3.13): %v", err)
	}
	if got := im.GetImageRef(); got != canon {
		t.Errorf("image ref = %q, want %q", got, canon)
	}
	if len(fetched) != 2 || fetched[0] != "python:3.13" || fetched[1] != canon {
		t.Errorf("fetch sequence = %v, want [python:3.13 %s]", fetched, canon)
	}
	if rec, ok := s.LookupRef(canon); !ok || rec.Ref != canon {
		t.Errorf("row not persisted under %q (ok=%v)", canon, ok)
	}

	// Verbatim ref hits on the FIRST attempt — no rewrite, no extra call.
	fetched = nil
	im, err = PullManifest(context.Background(), s, puller, verbatim)
	if err != nil {
		t.Fatalf("PullManifest(%s): %v", verbatim, err)
	}
	if got := im.GetImageRef(); got != verbatim {
		t.Errorf("image ref = %q, want %q", got, verbatim)
	}
	if len(fetched) != 1 || fetched[0] != verbatim {
		t.Errorf("fetch sequence = %v, want [%s]", fetched, verbatim)
	}

	// Total miss surfaces the original (raw-ref) error.
	fetched = nil
	if _, err := PullManifest(context.Background(), s, puller, "nope:1"); err == nil {
		t.Fatal("expected error for unresolvable ref")
	}
	if len(fetched) < 1 || fetched[0] != "nope:1" {
		t.Errorf("fetch sequence = %v, want it to start at nope:1", fetched)
	}
}
