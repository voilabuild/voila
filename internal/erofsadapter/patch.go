package erofsadapter

import (
	"encoding/binary"
	"fmt"
	"io/fs"

	"github.com/erofs/go-erofs"
)

// EROFS on-disk constants (from linux/fs/erofs/erofs_fs.h).
const (
	sbOffset       = 1024
	sbSize         = 128
	inodeCompact   = 32
	inodeExtended  = 64
	chunkIndexSize = 8

	iVersionBit      = 0
	iDatalayoutBit   = 1
	layoutChunkBased = 4

	// Null chunk index: StartBlkHi=0xFFFF, StartBlkLo=0xFFFFFFFF.
	nullStartBlkHi = 0xFFFF
	nullStartBlkLo = 0xFFFFFFFF
)

// patchToDevice0 post-processes the EROFS image built by go-erofs to change
// chunk index DeviceID from 1 (extra device) to 0 (primary device) and
// adjust block addresses to be absolute (relative to the start of the NBD
// device, not relative to device 1). It also clears the device table so the
// kernel doesn't look for an extra device.
//
// This is necessary because go-erofs's chunksFromRanges always assigns
// DeviceID=1 to DataRange data, but we serve everything from a single NBD
// device.
func patchToDevice0(image []byte, walk *walkResult) ([]byte, error) {
	if len(image) < sbOffset+sbSize {
		return nil, fmt.Errorf("image too small: %d bytes", len(image))
	}

	sb := image[sbOffset:]
	blockSize := int(1) << sb[12]
	metaBlkAddr := binary.LittleEndian.Uint32(sb[40:44])
	blocks := binary.LittleEndian.Uint32(sb[36:40])
	featureIncompat := binary.LittleEndian.Uint32(sb[80:84])
	extraDevices := binary.LittleEndian.Uint16(sb[86:88])

	metadataBlocks := uint32(blocks)
	metaStart := int64(metaBlkAddr) * int64(blockSize)

	// Use go-erofs's reader to walk the image and find chunk-based files.
	// The reader gives us each file's NID via Sys().(*erofs.Stat).Ino.
	imgFS, err := erofs.Open(bytesReaderAt(image), erofs.WithExtraDevices(zeroReaderAt(0)))
	if err != nil {
		return nil, fmt.Errorf("erofs.Open for patch: %w", err)
	}

	patched := make(map[int64]bool)
	err = fs.WalkDir(imgFS, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		f, err := imgFS.Open(p)
		if err != nil {
			return nil
		}
		info, err := f.Stat()
		_ = f.Close()
		if err != nil {
			return nil
		}

		// Get the NID from the reader's Stat.
		nid := int64(-1)
		type statHolder interface {
			Sys() any
		}
		if sh, ok := any(info).(statHolder); ok {
			if st, ok := sh.Sys().(*erofs.Stat); ok {
				nid = st.Ino
			}
		}
		if nid < 0 {
			return nil
		}

		// Skip already-patched inodes (hardlinks share the same inode).
		if patched[nid] {
			return nil
		}
		patched[nid] = true

		// Compute the inode location: iloc = metaStart + nid * 32.
		iloc := metaStart + nid*inodeCompact
		if iloc+inodeCompact > int64(len(image)) {
			return nil
		}

		// Read i_format to check if this is a chunk-based inode.
		iFormat := binary.LittleEndian.Uint16(image[iloc : iloc+2])
		datalayout := (iFormat >> iDatalayoutBit) & 0x07
		if datalayout != layoutChunkBased {
			return nil
		}

		// Read i_xattr_icount to compute xattr size.
		xattrCount := binary.LittleEndian.Uint16(image[iloc+2 : iloc+4])
		xattrSize := 0
		if xattrCount > 0 {
			xattrSize = 12 + 4*(int(xattrCount)-1)
		}

		// Determine inode size (compact vs extended).
		inodeSize := inodeCompact
		if iFormat&(1<<iVersionBit) != 0 {
			inodeSize = inodeExtended
		}

		// Chunk indexes start at ALIGN(iloc + inodeSize + xattrSize, 8).
		chunkIdxStart := iloc + int64(inodeSize) + int64(xattrSize)
		if rem := chunkIdxStart % 8; rem != 0 {
			chunkIdxStart += 8 - rem
		}

		// Read i_u to get the chunk size encoding.
		// For chunk-based inodes, i_u = LayoutChunkFormatIndexes | chunkBits.
		// chunkSize = blockSize << chunkBits.
		// i_u is at offset 16 in both compact and extended inodes.
		iU := binary.LittleEndian.Uint32(image[iloc+16 : iloc+20])
		chunkBits := iU & 0x1f
		chunkSize := int64(blockSize) << chunkBits

		// Number of chunk indexes = ceil(fileSize / chunkSize).
		fileSize := info.Size()
		nchunks := (fileSize + chunkSize - 1) / chunkSize

		for i := int64(0); i < nchunks; i++ {
			off := chunkIdxStart + i*chunkIndexSize
			if off+chunkIndexSize > int64(len(image)) {
				break
			}
			if isNullChunkIndex(image[off : off+chunkIndexSize]) {
				// Holes stay at EROFS_NULL_ADDR; adding metadataBlocks
				// would wrap 0xFFFFFFFF into a real (wrong) block.
				continue
			}
			// Patch DeviceID (bytes 2-3) from 1 to 0.
			deviceID := binary.LittleEndian.Uint16(image[off+2 : off+4])
			if deviceID == 1 {
				binary.LittleEndian.PutUint16(image[off+2:off+4], 0)
			}
			// Adjust startblk_lo (bytes 4-8) by adding metadataBlocks.
			startblk := binary.LittleEndian.Uint32(image[off+4 : off+8])
			startblk += metadataBlocks
			binary.LittleEndian.PutUint32(image[off+4:off+8], startblk)
		}

		// go-erofs has no WithChunkBits API. For non-contiguous files it
		// leaves chunkBits=0 (4 KiB chunks), producing thousands of
		// indexes. Collapse to one index per voila slot (1 MiB) so the
		// on-disk layout matches the NBD slot table.
		wantBits := slotChunkBits(blockSize)
		if chunkBits < wantBits {
			oldPerNew := int64(1) << (wantBits - chunkBits)
			newNchunks := (fileSize + int64(ChunkSize) - 1) / int64(ChunkSize)
			for i := int64(0); i < newNchunks; i++ {
				src := chunkIdxStart + i*oldPerNew*chunkIndexSize
				dst := chunkIdxStart + i*chunkIndexSize
				if src+chunkIndexSize > int64(len(image)) {
					break
				}
				if src != dst {
					copy(image[dst:dst+chunkIndexSize], image[src:src+chunkIndexSize])
				}
			}
			newIU := (iU &^ 0x1f) | wantBits
			binary.LittleEndian.PutUint32(image[iloc+16:iloc+20], newIU)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walk for patch: %w", err)
	}

	// Clear the device table in the superblock.
	if featureIncompat&0x08 != 0 { // FeatureIncompatDeviceTable
		featureIncompat &^= 0x08
		binary.LittleEndian.PutUint32(image[sbOffset+80:sbOffset+84], featureIncompat)
	}
	if extraDevices > 0 {
		binary.LittleEndian.PutUint16(image[sbOffset+86:sbOffset+88], 0)
	}

	return image, nil
}

// slotChunkBits returns the EROFS chunkBits that makes chunkSize == ChunkSize
// (1 MiB): chunkSize = blockSize << chunkBits.
func slotChunkBits(blockSize int) uint32 {
	if blockSize <= 0 || ChunkSize%blockSize != 0 {
		return 8
	}
	var bits uint32
	for cs := blockSize; cs < ChunkSize; cs <<= 1 {
		bits++
	}
	return bits
}

func isNullChunkIndex(idx []byte) bool {
	return binary.LittleEndian.Uint16(idx[0:2]) == nullStartBlkHi &&
		binary.LittleEndian.Uint32(idx[4:8]) == nullStartBlkLo
}

// bytesReaderAt wraps a []byte as an io.ReaderAt.
type bytesReaderAt []byte

func (b bytesReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if off >= int64(len(b)) {
		return 0, fmt.Errorf("EOF")
	}
	return copy(p, b[off:]), nil
}

// zeroReaderAt returns zeros for any read.
type zeroReaderAt int64

func (z zeroReaderAt) ReadAt(p []byte, off int64) (int, error) {
	for i := range p {
		p[i] = 0
	}
	return len(p), nil
}
