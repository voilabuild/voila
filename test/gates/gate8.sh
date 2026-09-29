#!/bin/bash
# Gate 8 — Phase 1.1 acceptance: layer reuse + one-file delta push.
# Two synthetic images share a base layer; image B changes ONE file in an
# upper layer. Asserts: (a) B's ingest reuses the cached base layer,
# (b) B's push uploads only the delta (changed file chunks + manifests).
# Also re-measures the python:3.13 ingest when /fixtures/python313.tar exists.
# Run INSIDE the privileged devcontainer image.
set -euo pipefail
. "$(dirname "$0")/_env.sh"

ROOT=/tmp/gate8-root
REG_ROOT=/tmp/gate8-reg
REG=http://127.0.0.1:7423
FIX=/tmp/gate8-fixtures
count_chunks() { if [ -d "$1" ]; then find "$1" -type f | wc -l; else echo 0; fi; }

echo "=== setup ==="
go build -o /usr/local/bin/voila ./cmd/voila
go build -o /usr/local/bin/voilad ./cmd/voilad
go build -o /usr/local/bin/voila-registry ./cmd/voila-registry
go test ./internal/ingest/ ./internal/registry/ 2>&1 | tail -2

echo "=== build fixtures: A(base+app v1), B(same base, one file changed) ==="
mkdir -p "$FIX"
cat > /tmp/mkpair.go <<'EOF'
package main

// mkpair emits two OCI image tarballs sharing an identical base layer.
// Image B's upper layer differs from A's by exactly one file's content.
import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
)

func layerTar(files map[string][]byte) []byte {
	var b bytes.Buffer
	tw := tar.NewWriter(&b)
	names := []string{}
	for n := range files {
		names = append(names, n)
	}
	// stable order
	for i := 0; i < len(names); i++ {
		for j := i + 1; j < len(names); j++ {
			if names[j] < names[i] {
				names[i], names[j] = names[j], names[i]
			}
		}
	}
	for _, n := range names {
		body := files[n]
		must(tw.WriteHeader(&tar.Header{Name: n, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(body))}))
		_, err := tw.Write(body)
		must(err)
	}
	must(tw.Close())
	return b.Bytes()
}

func ociTar(ref string, layers [][]byte) []byte {
	sha := func(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }
	config := []byte(`{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}`)
	layerJSON := ""
	for i, l := range layers {
		if i > 0 {
			layerJSON += ","
		}
		layerJSON += fmt.Sprintf(`{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:%s","size":%d}`, sha(l), len(l))
	}
	manifest := []byte(fmt.Sprintf(`{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%d},"layers":[%s]}`,
		sha(config), len(config), layerJSON))
	index := []byte(fmt.Sprintf(`{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%d,"annotations":{"io.containerd.image.name":%q}}]}`,
		sha(manifest), len(manifest), ref))
	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	add := func(name string, body []byte) {
		must(tw.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644, Size: int64(len(body))}))
		_, err := tw.Write(body)
		must(err)
	}
	add("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	add("index.json", index)
	add("blobs/sha256/"+sha(config), config)
	add("blobs/sha256/"+sha(manifest), manifest)
	seen := map[string]bool{}
	for _, l := range layers {
		if seen[sha(l)] {
			continue
		}
		seen[sha(l)] = true
		add("blobs/sha256/"+sha(l), l)
	}
	must(tw.Close())
	return out.Bytes()
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	// Base layer: ~60 MiB of pseudorandom files (the expensive part to re-chunk).
	rng := rand.New(rand.NewSource(7))
	base := map[string][]byte{}
	for i := 0; i < 12; i++ {
		buf := make([]byte, 5<<20)
		rng.Read(buf)
		base[fmt.Sprintf("lib/dep%02d.so", i)] = buf
	}
	baseTar := layerTar(base)

	appV1 := map[string][]byte{"app/main.py": []byte("print('v1')\n"), "app/util.py": []byte("def f(): pass\n")}
	appV2 := map[string][]byte{"app/main.py": []byte("print('v2')\n"), "app/util.py": []byte("def f(): pass\n")}

	must(os.WriteFile(os.Args[1]+"/imgA.tar", ociTar("pair:v1", [][]byte{baseTar, layerTar(appV1)}), 0o644))
	must(os.WriteFile(os.Args[1]+"/imgB.tar", ociTar("pair:v2", [][]byte{baseTar, layerTar(appV2)}), 0o644))
	fmt.Println("fixtures written")
}
EOF
go run /tmp/mkpair.go "$FIX"

echo "=== ingest A (cold: walks both layers) ==="
voila ingest -root "$ROOT" "$FIX/imgA.tar" | grep -E "layers reused|bytes in"

echo "=== ingest B (must REUSE the shared base layer) ==="
TB0=$(date +%s%N)
OUT=$(voila ingest -root "$ROOT" "$FIX/imgB.tar")
TB1=$(date +%s%N)
echo "$OUT" | grep -E "layers reused|bytes in"
echo "$OUT" | grep -q "layers reused:   1/2" || { echo "FAIL: B did not reuse the base layer"; exit 1; }
echo "ingest B wall: $(( (TB1 - TB0) / 1000000 ))ms (base layer NOT re-chunked)"

echo "=== push A, then push B — delta only ==="
voila-registry -root "$REG_ROOT" >/tmp/gate8-reg.log 2>&1 &
REG_PID=$!
for i in $(seq 1 50); do (echo > /dev/tcp/127.0.0.1/7423) 2>/dev/null && break; sleep 0.1; done
voila push -root "$ROOT" -registry "$REG" pair:v1 | tail -1
PUSH_B=$(voila push -root "$ROOT" -registry "$REG" pair:v2 | tail -1)
echo "$PUSH_B"
# The one-file delta: v2's changed file chunk(s) + a few manifest chunks.
UPLOADED=$(echo "$PUSH_B" | sed -E 's/.*: ([0-9]+) chunks uploaded.*/\1/')
[ "$UPLOADED" -ge 1 ] || { echo "FAIL: B push uploaded nothing"; exit 1; }
[ "$UPLOADED" -le 8 ] || { echo "FAIL: B push uploaded $UPLOADED chunks — not a one-file delta"; exit 1; }
echo "delta push OK: $UPLOADED chunks for a one-file change (image has $(count_chunks "$ROOT/chunks") chunks locally)"

if [ -f /fixtures/python313.tar ]; then
  echo "=== python:3.13 re-ingest (layer cache across identical image) ==="
  time voila ingest -root "$ROOT" /fixtures/python313.tar | grep -E "layers reused"
  time voila ingest -root "$ROOT" /fixtures/python313.tar | grep -E "layers reused"
fi

kill -TERM "$REG_PID"; wait "$REG_PID" 2>/dev/null || true
echo "GATE 8 PASSED — layer reuse + delta push work"
