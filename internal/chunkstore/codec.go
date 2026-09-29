package chunkstore

import (
	"errors"
	"strings"
	"sync"

	"github.com/klauspost/compress/zstd"
)

const (
	compRaw  = 0 // stored uncompressed
	compZstd = 1 // stored zstd
)

// AlgoRaw and AlgoZstd are the public wire-facing names for the on-disk
// compression algos recorded in the chunk index. They mirror the unexported
// compRaw / compZstd so the registry client + server can negotiate
// Content-Encoding without depending on the codec's internal numbering.
const (
	AlgoRaw  = compRaw
	AlgoZstd = compZstd
)

// AlgoName returns the wire name for an algo (e.g. "zstd"), or "" for raw /
// unknown. The registry client sets Content-Encoding to this when uploading a
// stored-compressed chunk; the server checks the same mapping on PUT.
func AlgoName(algo int) string {
	switch algo {
	case compZstd:
		return "zstd"
	default:
		return ""
	}
}

// AlgoFromName is the inverse of AlgoName: it maps a wire Content-Encoding
// value to the stored algo, returning AlgoRaw for "" / unknown (treated as
// uncompressed). The server uses this on PUT to decide whether to decompress
// the body before BLAKE3 verification.
func AlgoFromName(name string) int {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "zstd":
		return compZstd
	default:
		return compRaw
	}
}

// compressionThreshold is the raw size above which zstd is tried (plan §4.1).
const compressionThreshold = 4096

// encode chooses the smaller of {raw, zstd level-3} for buffers at least
// compressionThreshold bytes. Smaller buffers are always stored raw.
// Returns the stored bytes and the algo to record in the index.
func encode(buf []byte) (stored []byte, algo int) {
	if len(buf) < compressionThreshold {
		// Copy so the returned slice does not alias the caller's buffer.
		out := make([]byte, len(buf))
		copy(out, buf)
		return out, compRaw
	}
	enc, err := zstdEncoder()
	if err != nil {
		out := make([]byte, len(buf))
		copy(out, buf)
		return out, compRaw
	}
	compressed := enc.EncodeAll(buf, nil)
	if len(compressed) < len(buf) {
		return compressed, compZstd
	}
	out := make([]byte, len(buf))
	copy(out, buf)
	return out, compRaw
}

// decode reverses encode, returning the raw bytes for the given algo.
func decode(stored []byte, algo int) ([]byte, error) {
	return DecodeStored(stored, algo)
}

// DecodeStored reverses the on-disk / wire encoding, returning the raw bytes
// for the given algo. It is the exported form of decode, used by the registry
// server to decompress a PUT body (Content-Encoding: zstd) before its
// BLAKE3-against-id verification, and by the registry client to decompress a
// GET response (Content-Encoding: zstd) before its local write-through.
func DecodeStored(stored []byte, algo int) ([]byte, error) {
	switch algo {
	case compRaw:
		out := make([]byte, len(stored))
		copy(out, stored)
		return out, nil
	case compZstd:
		dec, err := zstdDecoder()
		if err != nil {
			return nil, err
		}
		return dec.DecodeAll(stored, nil)
	default:
		return nil, errors.New("chunkstore: unknown comp_algo")
	}
}

// EncodeZstd compresses buf with the shared zstd encoder (level 3, the same
// level encode() uses for on-disk storage). It is the wire-side companion to
// DecodeStored: the registry client uses it to compress a chunk body for a
// PUT when it only has the raw bytes (or a locally-raw-stored chunk) and the
// registry requires Content-Encoding: zstd on the wire. The id is the BLAKE3
// of the RAW bytes, and the server decompresses before verifying, so any
// valid zstd encoding of the raw content is acceptable.
func EncodeZstd(buf []byte) ([]byte, error) {
	enc, err := zstdEncoder()
	if err != nil {
		return nil, err
	}
	return enc.EncodeAll(buf, nil), nil
}

// Shared encoder/decoder. The EncodeAll/DecodeAll methods are safe for
// concurrent use once the encoder/decoder is constructed; init is guarded by
// sync.Once so there's no data race under concurrent first-use.
var (
	sharedEncoder *zstd.Encoder
	sharedDecoder *zstd.Decoder

	encOnce sync.Once
	decOnce sync.Once
	encErr  error
	decErr  error
)

func zstdEncoder() (*zstd.Encoder, error) {
	encOnce.Do(func() {
		sharedEncoder, encErr = zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(3)))
	})
	if encErr != nil {
		return nil, encErr
	}
	return sharedEncoder, nil
}

func zstdDecoder() (*zstd.Decoder, error) {
	decOnce.Do(func() {
		sharedDecoder, decErr = zstd.NewReader(nil)
	})
	if decErr != nil {
		return nil, decErr
	}
	return sharedDecoder, nil
}
