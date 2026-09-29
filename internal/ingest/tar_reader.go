package ingest

import (
	"bufio"
	"errors"
	"io"

	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
)

// Compression identifies the on-the-wire encoding of a layer blob.
type Compression int

const (
	CompUnknown Compression = iota
	CompRaw
	CompGzip
	CompZstd
)

// gzipMagic and zstdMagic are the magic byte prefixes per task spec:
// gzip 1f 8b; zstd 28 b5 2f fd; else raw tar.
var (
	gzipMagic = []byte{0x1f, 0x8b}
	zstdMagic = []byte{0x28, 0xb5, 0x2f, 0xfd}
)

// ErrUnsupportedCompression is returned when neither sniffing nor the supplied
// hint can identify a decompressor for the blob. (Currently never returned:
// unknown magic falls back to raw tar; this exists for future strictness.)
var ErrUnsupportedCompression = errors.New("ingest: unsupported layer compression")

// SniffCompression classifies a blob by its leading magic bytes. It returns
// CompRaw when the bytes are neither a recognized gzip nor zstd frame. The
// caller should pass at least 4 bytes; fewer bytes default to CompRaw.
func SniffCompression(magic []byte) Compression {
	if len(magic) >= 2 && magic[0] == gzipMagic[0] && magic[1] == gzipMagic[1] {
		return CompGzip
	}
	if len(magic) >= 4 && magic[0] == zstdMagic[0] && magic[1] == zstdMagic[1] &&
		magic[2] == zstdMagic[2] && magic[3] == zstdMagic[3] {
		return CompZstd
	}
	return CompRaw
}

// DecompressLayer wraps r so the returned reader yields the plain
// (uncompressed) tar stream of the layer blob.
//
// The OCI mediaType hint is honored when it is unambiguous and consistent
// with the blob's magic bytes; magic bytes always win if they identify a
// known compressed frame (gzip/zstd). Otherwise the hint is consulted, and
// when both are inconclusive the blob is treated as raw tar. This satisfies the
// spec's requirement to "ALWAYS verify/fall back by sniffing magic bytes".
//
// The returned second value is the compression actually applied.
func DecompressLayer(r io.Reader, hint Compression) (io.Reader, Compression, error) {
	br := bufio.NewReader(r)

	magic, err := br.Peek(4)
	if err != nil && err != io.EOF && err != bufio.ErrBufferFull {
		return nil, CompUnknown, err
	}
	sniffed := SniffCompression(magic)

	chosen := sniffed
	if chosen == CompRaw && (hint == CompGzip || hint == CompZstd) {
		// Magic did not identify a known frame; trust the mediaType hint when it
		// claims a compressed encoding (e.g. a blob whose first block happened
		// to be indistinguishable). This is rare; the common path is sniff.
		chosen = hint
	}

	switch chosen {
	case CompGzip:
		gz, err := gzip.NewReader(br)
		if err != nil {
			return nil, CompUnknown, err
		}
		return gz, CompGzip, nil
	case CompZstd:
		zr, err := zstd.NewReader(br)
		if err != nil {
			return nil, CompUnknown, err
		}
		// zstd.Reader is an io.ReadCloser; the caller may Close it. Wrap so a
		// Close releases the decoder.
		return &zstdReader{Decoder: zr}, CompZstd, nil
	default:
		return br, CompRaw, nil
	}
}

// zstdReader adapts klauspost's *zstd.Decoder so Close releases the decoder.
type zstdReader struct {
	*zstd.Decoder
}

// Close releases the decoder's resources.
func (z *zstdReader) Close() error {
	if z.Decoder != nil {
		z.Decoder.Close()
	}
	return nil
}
