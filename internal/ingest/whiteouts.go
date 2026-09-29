package ingest

import (
	"path"
	"strings"
)

// WhiteoutEntry records an explicit per-name whiteout (basename .wh.<name>)
// in a parent directory. At merge time the named child of Parent is removed
// from all lower layers.
type WhiteoutEntry struct {
	Parent string // cleaned dir path owning the .wh.<name> entry; "" for root
	Name   string // the name being whited out (the .wh. prefix stripped)
}

// OpaqueBase is the basename used for opaque whiteouts in the overlay/AUFS
// convention that OCI/docker tarballs reuse.
const OpaqueBase = ".wh..wh..opq"

// WhiteoutPrefix is the basename prefix for explicit whiteouts.
const WhiteoutPrefix = ".wh."

// ClassifyEntry inspects a tar entry's cleaned name and reports whether it is a
// whiteout entry. Returns:
//
//   - opaque == true, parent = the entry's containing dir, when basename is
//     OpaqueBase (.wh..wh..opq). Name is "".
//   - explicit == true, parent = containing dir, name = the whited-out name
//     when basename has the .wh. prefix (and is not the opaque marker).
//   - both false otherwise; the entry is a normal filesystem entry.
//
// entryPath is the cleaned, rootfs-relative entry path (as produced by
// cleanEntryPath).
func ClassifyEntry(entryPath string) (parent string, name string, explicit, opaque bool) {
	base := path.Base(entryPath)
	parent = path.Dir(entryPath)
	if parent == "." {
		parent = ""
	}
	switch {
	case base == OpaqueBase:
		return parent, "", false, true
	case strings.HasPrefix(base, WhiteoutPrefix) && len(base) > len(WhiteoutPrefix):
		return parent, base[len(WhiteoutPrefix):], true, false
	default:
		return parent, "", false, false
	}
}
