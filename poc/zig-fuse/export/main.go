//go:build zig_fuse_export

// Exports a flattened mount index for poc/zig-fuse (Zig reads JSON + voila chunk store).
//
//	go run -tags zig_fuse_export ./poc/zig-fuse/export -root /var/lib/voila -image alpine -o /tmp/zig-index.json
package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"

	"voila/internal/chunkstore"
	"voila/internal/imagestore"
	"voila/internal/mount"
)

func main() {
	root := flag.String("root", "", "voila store root (chunks/ + images.db)")
	image := flag.String("image", "", "image ref to resolve in images.db")
	manifestHex := flag.String("manifest", "", "merged root manifest chunk id (64-char hex); skips images.db")
	out := flag.String("o", "zig-index.json", "output JSON path")
	prefetch := flag.Int("prefetch", 32, "parallel manifest prefetch concurrency (0 = lazy only)")
	flag.Parse()

	if *root == "" {
		fmt.Fprintln(os.Stderr, "need -root")
		os.Exit(2)
	}
	if *image == "" && *manifestHex == "" {
		fmt.Fprintln(os.Stderr, "need -image or -manifest")
		os.Exit(2)
	}

	store, err := chunkstore.OpenLocal(*root)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open store: %v\n", err)
		os.Exit(1)
	}
	defer store.Close()

	var rootCID chunkstore.ChunkID
	if *manifestHex != "" {
		id, err := chunkstore.ParseChunkID(strings.TrimSpace(*manifestHex))
		if err != nil {
			fmt.Fprintf(os.Stderr, "parse manifest: %v\n", err)
			os.Exit(1)
		}
		rootCID = id
	} else {
		imgs, err := imagestore.Open(*root)
		if err != nil {
			fmt.Fprintf(os.Stderr, "open imagestore: %v\n", err)
			os.Exit(1)
		}
		defer imgs.Close()
		_, cid, err := imagestore.Resolve(imgs, *image)
		if err != nil {
			fmt.Fprintf(os.Stderr, "resolve image: %v\n", err)
			os.Exit(1)
		}
		rootCID = cid
	}

	ctx := context.Background()
	tree, err := mount.Load(ctx, store, rootCID)
	if err != nil {
		fmt.Fprintf(os.Stderr, "load tree: %v\n", err)
		os.Exit(1)
	}
	if *prefetch > 0 {
		tree.PrefetchManifests(ctx, *prefetch)
	}

	idx, err := buildIndex(ctx, *root, store, tree)
	if err != nil {
		fmt.Fprintf(os.Stderr, "build index: %v\n", err)
		os.Exit(1)
	}
	f, err := os.Create(*out)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(idx); err != nil {
		_ = f.Close()
		fmt.Fprintf(os.Stderr, "encode: %v\n", err)
		os.Exit(1)
	}
	if err := f.Close(); err != nil {
		fmt.Fprintf(os.Stderr, "close: %v\n", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "wrote %s (root_ino=%d)\n", *out, idx.RootIno)
}

type Index struct {
	VoilaRoot string            `json:"voila_root"`
	RootIno   uint64            `json:"root_ino"`
	Dirs      map[string]Dir    `json:"dirs"`
	Files     map[string]File   `json:"files"`
	Symlinks  map[string]Link   `json:"symlinks"`
	Devices   map[string]Device `json:"devices"`
}

type Dir struct {
	Mode    uint32            `json:"mode"`
	Uid     uint32            `json:"uid"`
	Gid     uint32            `json:"gid"`
	MtimeNs uint64            `json:"mtime_ns"`
	Entries map[string]uint64 `json:"entries"`
}

type File struct {
	Mode    uint32  `json:"mode"`
	Uid     uint32  `json:"uid"`
	Gid     uint32  `json:"gid"`
	Size    uint64  `json:"size"`
	MtimeNs uint64  `json:"mtime_ns"`
	Nlink   uint32  `json:"nlink"`
	Blocks  []Block `json:"blocks"`
}

type Block struct {
	Offset     uint64 `json:"offset"`
	ChunkHex   string `json:"chunk_hex"`
	LogicalLen uint64 `json:"logical_len"`
	Algo       int    `json:"algo"`
}

type Link struct {
	Target string `json:"target"`
	Uid    uint32 `json:"uid"`
	Gid    uint32 `json:"gid"`
}

type Device struct {
	Mode       uint32 `json:"mode"`
	Uid        uint32 `json:"uid"`
	Gid        uint32 `json:"gid"`
	RdevMajor  uint32 `json:"rdev_major"`
	RdevMinor  uint32 `json:"rdev_minor"`
	IsChar     bool   `json:"is_char"`
}

func buildIndex(ctx context.Context, voilaRoot string, store chunkstore.ChunkStore, tree *mount.Tree) (*Index, error) {
	idx := &Index{
		VoilaRoot: voilaRoot,
		RootIno:   tree.Root(),
		Dirs:      make(map[string]Dir),
		Files:     make(map[string]File),
		Symlinks:  make(map[string]Link),
		Devices:   make(map[string]Device),
	}
	seen := make(map[uint64]struct{})
	var walk func(ino uint64) error
	walk = func(ino uint64) error {
		if _, ok := seen[ino]; ok {
			return nil
		}
		seen[ino] = struct{}{}
		info, err := tree.Get(ctx, ino)
		if err != nil {
			return err
		}
		key := fmt.Sprintf("%d", ino)
		switch info.Kind {
		case mount.KindDir:
			d := info.Dir
			ent := make(map[string]uint64, len(d.Entries))
			for n, c := range d.Entries {
				ent[n] = c
			}
			idx.Dirs[key] = Dir{
				Mode:    d.Mode,
				Uid:     d.Uid,
				Gid:     d.Gid,
				MtimeNs: d.MtimeNs,
				Entries: ent,
			}
			entries, err := tree.ReadDir(ctx, ino)
			if err != nil {
				return err
			}
			for _, e := range entries {
				if err := walk(e.Inode); err != nil {
					return err
				}
			}
		case mount.KindFile:
			f := info.File
			blocks := make([]Block, 0, len(f.Blocks))
			for _, b := range f.Blocks {
				hexID := ""
				algo := 0
				if len(b.ChunkId) == len(chunkstore.ChunkID{}) {
					var id chunkstore.ChunkID
					copy(id[:], b.ChunkId)
					hexID = id.String()
					if sr, ok := store.(chunkstore.StoredReader); ok {
						_, algo, err = sr.GetStored(id)
						if err != nil {
							return fmt.Errorf("stored chunk %s: %w", hexID, err)
						}
					}
				}
				blocks = append(blocks, Block{
					Offset:     b.OffsetInFile,
					ChunkHex:   hexID,
					LogicalLen: b.LogicalLen,
					Algo:       algo,
				})
			}
			idx.Files[key] = File{
				Mode:    f.Mode,
				Uid:     f.Uid,
				Gid:     f.Gid,
				Size:    f.Size,
				MtimeNs: f.MtimeNs,
				Nlink:   f.Nlink,
				Blocks:  blocks,
			}
		case mount.KindSymlink:
			s := info.Symlink
			idx.Symlinks[key] = Link{
				Target: s.Target,
				Uid:    s.Uid,
				Gid:    s.Gid,
			}
		case mount.KindDevice:
			dv := info.Device
			idx.Devices[key] = Device{
				Mode:      dv.Mode,
				Uid:       dv.Uid,
				Gid:       dv.Gid,
				RdevMajor: dv.RdevMajor,
				RdevMinor: dv.RdevMinor,
				IsChar:    dv.IsChar,
			}
		default:
			return fmt.Errorf("unknown kind for inode %d", ino)
		}
		return nil
	}
	if err := walk(tree.Root()); err != nil {
		return nil, err
	}
	return idx, nil
}

// unused but documents expected hex layout for tests
func _hex32(b []byte) string { return hex.EncodeToString(b) }
