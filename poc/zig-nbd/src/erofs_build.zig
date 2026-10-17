const std = @import("std");
const voila_tree = @import("voila_tree.zig");
const voila_manifest_proto = @import("manifest/voila_manifest_proto.zig");
const voila_store = @import("voila_store.zig");
const constants = @import("constants.zig");
const hex_util = @import("hex_util.zig");

extern "c" fn time(t: ?*i64) i64;

pub const ChunkSize = constants.chunk_size;
const BlockSize = constants.block_size;

const Magic: u32 = 0xe0f5e1e2;
const SbOffset = 1024;
const SbSize = 128;
const InodeCompact = 32;
const InodeExtended = 64;
const DirentSize = 12;
const ChunkIndexSize = 8;

const LayoutFlatPlain: u8 = 0;
const LayoutFlatInline: u8 = 2;
const LayoutChunkBased: u8 = 4;
const LayoutChunkFormatIndexes: u32 = 0x20;

const StatTypeReg: u16 = 0o100000;
const StatTypeDir: u16 = 0o040000;
const StatTypeChrdev: u16 = 0o020000;
const StatTypeBlkdev: u16 = 0o060000;
const StatTypeSymlink: u16 = 0o120000;

const FileTypeReg: u8 = 1;
const FileTypeDir: u8 = 2;
const FileTypeChrdev: u8 = 3;
const FileTypeBlkdev: u8 = 4;
const FileTypeSymlink: u8 = 7;

const SlotChunkBits: u32 = 8;

pub const BuildResult = struct {
    metadata: []u8,
    slot_hex: []const []const u8,
    data_offset: u64,
    device_size: u64,
    files: u64,
    dirs: u64,
    symlinks: u64,
    devices: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BuildResult) void {
        self.allocator.free(self.metadata);
        for (self.slot_hex) |h| self.allocator.free(h);
        self.allocator.free(self.slot_hex);
    }
};

const Kind = enum { dir, file, symlink, device };

const Entry = struct {
    path: []const u8,
    name: []const u8,
    inode: u64,
    kind: Kind,
    mode: u16,
    uid: u32,
    gid: u32,
    mtime_ns: u64,
    nlink: u32,
    size: u64,
    sym_target: []const u8,
    rdev: u32,
    blocks: []const voila_manifest_proto.BlockMsg,
    children: []usize,
    parent_idx: usize,
    nid: u64 = 0,
    parent_nid: u64 = 0,
    compact: bool = false,
    layout: u8 = LayoutFlatPlain,
    trailing: usize = 0,
    data_blk_addr: u32 = 0,
    file_slots: []u64,
};

fn linuxRdev(major: u32, minor: u32) u32 {
    return (minor & 0xff) | (major << 8) | ((minor & 0xfff00) << 12);
}

fn joinPath(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(allocator, "/{s}", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) return "/";
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[idx + 1 ..];
}

fn sortStrings(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, names.len);
    @memcpy(copy, names);
    std.mem.sort([]const u8, copy, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return copy;
}

fn chunkKey(chunk_id: []const u8) [32]u8 {
    std.debug.assert(chunk_id.len == 32);
    var k: [32]u8 = undefined;
    @memcpy(&k, chunk_id);
    return k;
}

fn assignSlotsForFile(
    allocator: std.mem.Allocator,
    blocks: []const voila_manifest_proto.BlockMsg,
    slot_map: *std.AutoHashMap([32]u8, u64),
    slot_list: *std.ArrayList([32]u8),
    file_slots: *std.ArrayList(u64),
) !void {
    var pos: u64 = 0;
    for (blocks) |b| {
        const blk_start = b.offset;
        if (blk_start > pos) pos = blk_start;
        const blk_len = if (b.logical_len == 0) ChunkSize else b.logical_len;
        if (b.chunk_id.len == 0) {
            pos = blk_start + blk_len;
            continue;
        }
        const key = chunkKey(b.chunk_id);
        const slot = if (slot_map.get(key)) |s| s else blk: {
            const idx: u64 = @intCast(slot_list.items.len);
            try slot_list.append(allocator, key);
            try slot_map.put(key, idx);
            break :blk idx;
        };
        try file_slots.append(allocator, slot);
        pos = blk_start + blk_len;
    }
}

fn walkTree(
    allocator: std.mem.Allocator,
    tree: *voila_tree.Tree,
    ino: u64,
    path: []const u8,
    parent_entry_idx: usize,
    entries: *std.ArrayList(Entry),
    slot_map: *std.AutoHashMap([32]u8, u64),
    slot_list: *std.ArrayList([32]u8),
) !void {
    try tree.ensureInode(ino);

    var kind: Kind = undefined;
    var mode: u16 = 0;
    var uid: u32 = 0;
    var gid: u32 = 0;
    var mtime_ns: u64 = 0;
    var nlink: u32 = 1;
    var size: u64 = 0;
    var sym_target: []const u8 = "";
    var rdev: u32 = 0;
    var blocks: []const voila_manifest_proto.BlockMsg = &.{};
    var child_inos: std.ArrayList(u64) = .empty;
    defer child_inos.deinit(allocator);

    if (tree.dir_by_inode.get(ino)) |d| {
        kind = .dir;
        mode = @intCast(d.mode | 0o040000);
        uid = d.uid;
        gid = d.gid;
        mtime_ns = d.mtime_ns;
        nlink = 2;
        var it = d.entries.keyIterator();
        while (it.next()) |k| {
            const child = d.entries.get(k.*) orelse continue;
            try child_inos.append(allocator, child);
        }
    } else if (tree.file_by_inode.get(ino)) |f| {
        kind = .file;
        mode = @intCast(f.mode | 0o100000);
        uid = f.uid;
        gid = f.gid;
        mtime_ns = f.mtime_ns;
        nlink = if (f.nlink > 0) f.nlink else 1;
        size = f.size;
        blocks = f.blocks;
    } else if (tree.symlink_by_inode.get(ino)) |l| {
        kind = .symlink;
        mode = 0o120777;
        uid = l.uid;
        gid = l.gid;
        size = l.target.len;
        sym_target = l.target;
    } else if (tree.device_by_inode.get(ino)) |dv| {
        kind = .device;
        mode = @intCast(if (dv.is_char) dv.mode | 0o020000 else dv.mode | 0o060000);
        uid = dv.uid;
        gid = dv.gid;
        rdev = linuxRdev(dv.rdev_major, dv.rdev_minor);
    } else {
        return error.InodeNotFound;
    }

    var file_slots: std.ArrayList(u64) = .empty;
    if (kind == .file) {
        try assignSlotsForFile(allocator, blocks, slot_map, slot_list, &file_slots);
    }

    const owned_path = try allocator.dupe(u8, path);
    const idx = entries.items.len;
    try entries.append(allocator, .{
        .path = owned_path,
        .name = baseName(owned_path),
        .inode = ino,
        .kind = kind,
        .mode = mode,
        .uid = uid,
        .gid = gid,
        .mtime_ns = mtime_ns,
        .nlink = nlink,
        .size = size,
        .sym_target = sym_target,
        .rdev = rdev,
        .blocks = blocks,
        .children = &.{},
        .parent_idx = parent_entry_idx,
        .file_slots = try file_slots.toOwnedSlice(allocator),
    });

    if (kind != .dir) return;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    if (tree.dir_by_inode.get(ino)) |d| {
        var it = d.entries.keyIterator();
        while (it.next()) |k| try names.append(allocator, k.*);
    }
    const sorted = try sortStrings(allocator, names.items);
    defer allocator.free(sorted);

    var child_indices: std.ArrayList(usize) = .empty;
    for (sorted) |name| {
        const child_ino = tree.dir_by_inode.get(ino).?.entries.get(name) orelse continue;
        const child_path = try joinPath(allocator, path, name);
        defer allocator.free(child_path);
        try walkTree(allocator, tree, child_ino, child_path, idx, entries, slot_map, slot_list);
        try child_indices.append(allocator, entries.items.len - 1);
    }
    entries.items[idx].children = try child_indices.toOwnedSlice(allocator);
}

fn inodeFormat(layout: u8, compact: bool) u16 {
    var f: u16 = @as(u16, @intCast(layout)) << 1;
    if (!compact) f |= 1;
    return f;
}

fn direntNames(allocator: std.mem.Allocator, e: *const Entry, entries: []const Entry) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(allocator, ".");
    try names.append(allocator, "..");
    for (e.children) |ci| {
        try names.append(allocator, entries[ci].name);
    }
    return sortStrings(allocator, names.items);
}

fn direntDataSize(allocator: std.mem.Allocator, e: *const Entry, entries: []const Entry) !usize {
    const names = try direntNames(allocator, e, entries);
    defer allocator.free(names);
    const n_entries = names.len;
    if (e.children.len == 0) {
        return 2 * DirentSize + 1 + 2;
    }
    var total: usize = 0;
    var i: usize = 0;
    while (i < n_entries) {
        var block_used: usize = 0;
        const start = i;
        var name_size: usize = 0;
        while (i < n_entries) {
            const header_size = (i - start + 1) * DirentSize;
            name_size += names[i].len;
            const needed = header_size + name_size;
            if (needed > BlockSize) break;
            block_used = needed;
            i += 1;
        }
        if (i == start) {
            block_used = DirentSize + names[i].len;
            i += 1;
        }
        if (i < n_entries and block_used % BlockSize != 0) {
            block_used = (block_used + BlockSize - 1) & ~@as(usize, BlockSize - 1);
        }
        total += block_used;
    }
    return total;
}

fn calcTrailing(allocator: std.mem.Allocator, e: *Entry, entries: []const Entry) !usize {
    switch (e.kind) {
        .file => {
            if (e.layout == LayoutChunkBased) {
                if (e.size == 0 and e.blocks.len == 0) return 0;
                const nchunks = @as(usize, @intCast((e.size + ChunkSize - 1) / ChunkSize));
                return nchunks * ChunkIndexSize;
            }
            if (e.layout == LayoutFlatInline) return @intCast(e.size);
            return 0;
        },
        .dir => {
            if (e.layout == LayoutFlatInline) return try direntDataSize(allocator, e, entries);
            return 0;
        },
        .symlink => {
            if (e.layout == LayoutFlatInline) return e.sym_target.len;
            return 0;
        },
        .device => return 0,
    }
}

fn planLayout(allocator: std.mem.Allocator, entries: []Entry, build_time: u64, block_size: usize) !void {
    var current_off: usize = 0;
    for (entries) |*e| {
        const mtime: u64 = if (e.mtime_ns == 0) 0 else @divFloor(e.mtime_ns, 1_000_000_000);
        const mtime_ns: u32 = if (e.mtime_ns == 0) 0 else @intCast(e.mtime_ns % 1_000_000_000);
        e.compact = e.uid <= 0xffff and e.gid <= 0xffff and e.nlink <= 0xffff and e.size <= 0xffffffff and
            mtime == build_time and mtime_ns == 0;

        const inode_size: usize = if (e.compact) InodeCompact else InodeExtended;
        const header_size = inode_size;

        switch (e.kind) {
            .file => {
                if (e.size == 0 and e.blocks.len == 0) {
                    e.layout = LayoutFlatPlain;
                } else {
                    e.layout = LayoutChunkBased;
                }
            },
            .dir => {
                const ds = try direntDataSize(allocator, e, entries);
                const in_block = (current_off + header_size) % block_size;
                if (ds > 0 and in_block + ds <= block_size) {
                    e.layout = LayoutFlatInline;
                } else {
                    e.layout = LayoutFlatPlain;
                }
            },
            .symlink => {
                const in_block = (current_off + header_size) % block_size;
                if (e.sym_target.len > 0 and in_block + e.sym_target.len <= block_size) {
                    e.layout = LayoutFlatInline;
                } else {
                    e.layout = LayoutFlatPlain;
                }
            },
            .device => e.layout = LayoutFlatPlain,
        }

        e.trailing = try calcTrailing(allocator, e, entries);

        var total_inode = header_size + e.trailing;
        if (total_inode % 32 != 0) total_inode = (total_inode + 31) & ~@as(usize, 31);

        var block_off = current_off % block_size;
        if (block_off + inode_size > block_size) {
            current_off = (current_off + block_size - 1) & ~@as(usize, block_size - 1);
        }

        if (e.layout == LayoutFlatInline) {
            block_off = current_off % block_size;
            if (block_off + header_size + e.trailing > block_size) {
                e.layout = LayoutFlatPlain;
                e.trailing = try calcTrailing(allocator, e, entries);
                total_inode = header_size + e.trailing;
                if (total_inode % 32 != 0) total_inode = (total_inode + 31) & ~@as(usize, 31);
            }
        }

        e.nid = @intCast(current_off / 32);
        current_off += total_inode;
    }
}

fn fixParentNids(entries: []Entry, root_nid: u64) void {
    for (entries, 0..) |*e, i| {
        if (i == 0) {
            e.parent_nid = root_nid;
        } else {
            e.parent_nid = entries[e.parent_idx].nid;
        }
        if (e.kind == .dir) {
            var child_dirs: u32 = 0;
            for (e.children) |ci| {
                if (entries[ci].kind == .dir) child_dirs += 1;
            }
            e.nlink = 2 + child_dirs;
        }
    }
}

fn assignDataBlocks(allocator: std.mem.Allocator, entries: []Entry, sb_blocks: usize, block_size: usize) !void {
    var total_meta: usize = 0;
    for (entries) |e| {
        const inode_size: usize = if (e.compact) InodeCompact else InodeExtended;
        var sz = inode_size + e.trailing;
        if (sz % 32 != 0) sz = (sz + 31) & ~@as(usize, 31);
        const end = @as(usize, @intCast(e.nid * 32)) + sz;
        if (end > total_meta) total_meta = end;
    }
    var addr: u32 = @intCast(sb_blocks);
    for (entries) |*e| {
        var ds = flatPlainDataSize(e);
        if (e.kind == .dir and e.layout == LayoutFlatPlain) {
            ds = try direntDataSize(allocator, e, entries);
        }
        if (ds > 0) {
            e.data_blk_addr = addr;
            addr += @intCast((ds + block_size - 1) / block_size);
        }
    }
}

fn flatPlainDataSize(e: *const Entry) usize {
    if (e.layout != LayoutFlatPlain) return 0;
    switch (e.kind) {
        .file => return if (e.size > 0) @intCast(e.size) else 0,
        .dir => return 0, // computed separately when writing
        .symlink => return e.sym_target.len,
        .device => return 0,
    }
}

fn writeDirents(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), e: *const Entry, entries: []const Entry, block_size: usize) !usize {
    const names = try direntNames(allocator, e, entries);
    defer allocator.free(names);

    const Dirent = struct { name: []const u8, nid: u64, ftype: u8 };
    var all: std.ArrayList(Dirent) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, .{ .name = ".", .nid = e.nid, .ftype = FileTypeDir });
    try all.append(allocator, .{ .name = "..", .nid = e.parent_nid, .ftype = FileTypeDir });
    for (e.children) |ci| {
        const c = entries[ci];
        const ft: u8 = switch (c.kind) {
            .dir => FileTypeDir,
            .file => FileTypeReg,
            .symlink => FileTypeSymlink,
            .device => if ((c.mode & StatTypeChrdev) != 0) FileTypeChrdev else FileTypeBlkdev,
        };
        try all.append(allocator, .{ .name = c.name, .nid = c.nid, .ftype = ft });
    }

    var total: usize = 0;
    var i: usize = 0;
    while (i < all.items.len) {
        const start = i;
        var block_used: usize = 0;
        var name_size: usize = 0;
        while (i < all.items.len) {
            const header_size = (i - start + 1) * DirentSize;
            name_size += all.items[i].name.len;
            const needed = header_size + name_size;
            if (needed > block_size) break;
            block_used = needed;
            i += 1;
        }
        if (i == start) {
            block_used = DirentSize + all.items[i].name.len;
            i += 1;
        }
        const block_ents = all.items[start..i];
        const header_bytes = block_ents.len * DirentSize;
        var scratch: [DirentSize]u8 = undefined;
        var name_off: u16 = @intCast(header_bytes);
        for (block_ents, 0..) |de, j| {
            if (j > 0) name_off += @intCast(block_ents[j - 1].name.len);
            std.mem.writeInt(u64, scratch[0..8], de.nid, .little);
            std.mem.writeInt(u16, scratch[8..10], name_off, .little);
            scratch[10] = de.ftype;
            scratch[11] = 0;
            try buf.appendSlice(allocator, scratch[0..]);
            total += DirentSize;
        }
        for (block_ents) |de| {
            try buf.appendSlice(allocator, de.name);
            total += de.name.len;
        }
        if (i < all.items.len and block_used % block_size != 0) {
            const pad = block_size - (block_used % block_size);
            try buf.appendNTimes(allocator, 0, pad);
            total += pad;
        }
    }
    return total;
}

fn slotForOffset(
    blocks: []const voila_manifest_proto.BlockMsg,
    file_size: u64,
    pos: u64,
    slot_map: *const std.AutoHashMap([32]u8, u64),
) ?u64 {
    var cursor: u64 = 0;
    for (blocks) |b| {
        const start = b.offset;
        if (start > cursor and pos < start) return null;
        if (start > cursor) cursor = start;
        const len = if (b.logical_len == 0) ChunkSize else b.logical_len;
        if (pos >= start and pos < start + len) {
            if (b.chunk_id.len == 0) return null;
            const key = chunkKey(b.chunk_id);
            return slot_map.get(key);
        }
        cursor = start + len;
    }
    if (pos < file_size) return null;
    return null;
}

fn writeChunkIndexes(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    e: *const Entry,
    slot_map: *const std.AutoHashMap([32]u8, u64),
    image_blocks: u32,
) !void {
    const nchunks = @as(usize, @intCast((e.size + ChunkSize - 1) / ChunkSize));
    var null_idx: [ChunkIndexSize]u8 = undefined;
    std.mem.writeInt(u16, null_idx[0..2], 0xffff, .little);
    std.mem.writeInt(u16, null_idx[2..4], 0, .little);
    std.mem.writeInt(u32, null_idx[4..8], 0xffffffff, .little);

    var i: u64 = 0;
    while (i < nchunks) : (i += 1) {
        const pos = i * ChunkSize;
        const slot = slotForOffset(e.blocks, e.size, pos, slot_map);
        if (slot == null) {
            try buf.appendSlice(allocator, &null_idx);
            continue;
        }
        const blocks_per_slot = ChunkSize / BlockSize;
        const start_blk = image_blocks + slot.? * blocks_per_slot;
        var idx: [ChunkIndexSize]u8 = undefined;
        std.mem.writeInt(u16, idx[0..2], @intCast(start_blk >> 32), .little);
        std.mem.writeInt(u16, idx[2..4], 0, .little);
        std.mem.writeInt(u32, idx[4..8], @truncate(start_blk), .little);
        try buf.appendSlice(allocator, &idx);
    }
}

fn writeInode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), e: *const Entry, build_time: u64) !void {
    var inode_data: u32 = 0;
    var file_size = e.size;
    switch (e.kind) {
        .file => {
            if (e.layout == LayoutChunkBased) {
                inode_data = LayoutChunkFormatIndexes | SlotChunkBits;
            } else if (e.layout == LayoutFlatPlain and e.size > 0) {
                inode_data = e.data_blk_addr;
            }
        },
        .dir, .symlink => {
            if (e.layout == LayoutFlatPlain) inode_data = e.data_blk_addr;
        },
        .device => inode_data = e.rdev,
    }
    if (e.kind == .dir) {
        file_size = e.trailing;
    } else if (e.kind == .symlink) {
        file_size = e.sym_target.len;
    }

    var b: [InodeExtended]u8 = undefined;
    @memset(&b, 0);
    if (e.compact) {
        std.mem.writeInt(u16, b[0..2], inodeFormat(e.layout, true), .little);
        std.mem.writeInt(u16, b[4..6], e.mode, .little);
        std.mem.writeInt(u16, b[6..8], @intCast(e.nlink), .little);
        std.mem.writeInt(u32, b[8..12], @truncate(file_size), .little);
        std.mem.writeInt(u32, b[16..20], inode_data, .little);
        std.mem.writeInt(u16, b[24..26], @intCast(e.uid), .little);
        std.mem.writeInt(u16, b[26..28], @intCast(e.gid), .little);
        try buf.appendSlice(allocator, b[0..InodeCompact]);
    } else {
        const mtime: u64 = if (e.mtime_ns == 0) build_time else @divFloor(e.mtime_ns, 1_000_000_000);
        const mtime_ns: u32 = if (e.mtime_ns == 0) 0 else @intCast(e.mtime_ns % 1_000_000_000);
        std.mem.writeInt(u16, b[0..2], inodeFormat(e.layout, false), .little);
        std.mem.writeInt(u16, b[4..6], e.mode, .little);
        std.mem.writeInt(u64, b[8..16], file_size, .little);
        std.mem.writeInt(u32, b[16..20], inode_data, .little);
        std.mem.writeInt(u32, b[24..28], e.uid, .little);
        std.mem.writeInt(u32, b[28..32], e.gid, .little);
        std.mem.writeInt(u64, b[32..40], mtime, .little);
        std.mem.writeInt(u32, b[40..44], mtime_ns, .little);
        std.mem.writeInt(u32, b[44..48], e.nlink, .little);
        try buf.appendSlice(allocator, b[0..InodeExtended]);
    }
}

pub fn build(allocator: std.mem.Allocator, tree: *voila_tree.Tree) !BuildResult {
    var slot_map: std.AutoHashMap([32]u8, u64) = .init(allocator);
    defer slot_map.deinit();
    var slot_list: std.ArrayList([32]u8) = .empty;
    defer slot_list.deinit(allocator);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |*e| {
            allocator.free(e.path);
            allocator.free(e.children);
            allocator.free(e.file_slots);
        }
        entries.deinit(allocator);
    }

    try walkTree(allocator, tree, tree.root_ino, "/", 0, &entries, &slot_map, &slot_list);
    if (entries.items.len == 0) return error.EmptyTree;

    const build_time: u64 = @intCast(time(null));
    const entries_mut = entries.items;
    try planLayout(allocator, entries_mut, build_time, BlockSize);
    const root_nid = entries_mut[0].nid;
    fixParentNids(entries_mut, root_nid);

    const sb_area_blocks = 1;
    const sb_area_size = sb_area_blocks * BlockSize;
    try assignDataBlocks(allocator, entries_mut, sb_area_blocks, BlockSize);

    var data_buf: std.ArrayList(u8) = .empty;
    defer data_buf.deinit(allocator);
    for (entries_mut) |*e| {
        if (e.kind == .dir and e.layout == LayoutFlatPlain) {
            const ds = try direntDataSize(allocator, e, entries_mut);
            _ = ds;
            const n = try writeDirents(allocator, &data_buf, e, entries_mut, BlockSize);
            if (n % BlockSize != 0) try data_buf.appendNTimes(allocator, 0, BlockSize - (n % BlockSize));
        } else if (e.kind == .symlink and e.layout == LayoutFlatPlain) {
            try data_buf.appendSlice(allocator, e.sym_target);
            if (e.sym_target.len % BlockSize != 0) {
                try data_buf.appendNTimes(allocator, 0, BlockSize - (e.sym_target.len % BlockSize));
            }
        }
    }

    var meta_buf: std.ArrayList(u8) = .empty;
    defer meta_buf.deinit(allocator);
    var meta_pos: usize = 0;
    for (entries_mut) |*e| {
        const expected = @as(usize, @intCast(e.nid * 32));
        if (expected > meta_pos) {
            try meta_buf.appendNTimes(allocator, 0, expected - meta_pos);
            meta_pos = expected;
        }
        try writeInode(allocator, &meta_buf, e, build_time);
        meta_pos += if (e.compact) @as(usize, InodeCompact) else InodeExtended;

        switch (e.kind) {
            .file => {
                if (e.layout == LayoutChunkBased) {
                    const image_blocks_placeholder: u32 = 0;
                    try writeChunkIndexes(allocator, &meta_buf, e, &slot_map, image_blocks_placeholder);
                    meta_pos += e.trailing;
                } else if (e.layout == LayoutFlatInline and e.size > 0) {
                    meta_pos += @intCast(e.size);
                }
            },
            .dir => {
                if (e.layout == LayoutFlatInline) {
                    const n = try writeDirents(allocator, &meta_buf, e, entries_mut, BlockSize);
                    meta_pos += n;
                }
            },
            .symlink => {
                if (e.layout == LayoutFlatInline) {
                    try meta_buf.appendSlice(allocator, e.sym_target);
                    meta_pos += e.sym_target.len;
                }
            },
            .device => {},
        }
        const inode_size: usize = if (e.compact) InodeCompact else InodeExtended;
        const total = inode_size + e.trailing;
        const padded = if (total % 32 != 0) (total + 31) & ~@as(usize, 31) else total;
        if (padded > inode_size + e.trailing) {
            try meta_buf.appendNTimes(allocator, 0, padded - inode_size - e.trailing);
            meta_pos += padded - inode_size - e.trailing;
        }
    }
    if (meta_buf.items.len % BlockSize != 0) {
        try meta_buf.appendNTimes(allocator, 0, BlockSize - (meta_buf.items.len % BlockSize));
    }

    const meta_blocks = meta_buf.items.len / BlockSize;
    const data_blocks = data_buf.items.len / BlockSize;
    const total_blocks = sb_area_blocks + data_blocks + meta_blocks;

    // Rewrite chunk indexes with final image_blocks = total_blocks
    // (second pass over file inodes in metadata)
    const meta_blk: u32 = @intCast(sb_area_blocks + data_blocks);
    const meta_start = meta_blk * BlockSize;

    var image: std.ArrayList(u8) = .empty;
    try image.appendNTimes(allocator, 0, sb_area_size);
    try image.appendSlice(allocator, data_buf.items);
    try image.appendSlice(allocator, meta_buf.items);

    writeSuperblock(image.items, root_nid, @intCast(entries_mut.len), build_time, @intCast(total_blocks), meta_blk);
    patchChunkPass(image.items, meta_start, entries_mut, &slot_map, @intCast(total_blocks));

    const data_offset: u64 = @intCast(image.items.len);
    const padded_meta = (data_offset + BlockSize - 1) & ~@as(u64, BlockSize - 1);
    if (padded_meta > data_offset) {
        try image.appendNTimes(allocator, 0, @intCast(padded_meta - data_offset));
    }
    const device_size = padded_meta + @as(u64, slot_list.items.len) * ChunkSize;

    var slot_hex: std.ArrayList([]const u8) = .empty;
    for (slot_list.items) |id| {
        const hex = try hex_util.allocHexLower(allocator, &id);
        try slot_hex.append(allocator, hex);
    }

    var files: u64 = 0;
    var dirs: u64 = 0;
    var symlinks: u64 = 0;
    var devices: u64 = 0;
    for (entries_mut) |e| {
        switch (e.kind) {
            .file => files += 1,
            .dir => dirs += 1,
            .symlink => symlinks += 1,
            .device => devices += 1,
        }
    }

    return .{
        .metadata = try image.toOwnedSlice(allocator),
        .slot_hex = try slot_hex.toOwnedSlice(allocator),
        .data_offset = padded_meta,
        .device_size = device_size,
        .files = files,
        .dirs = dirs,
        .symlinks = symlinks,
        .devices = devices,
        .allocator = allocator,
    };
}

fn patchChunkPass(meta: []u8, meta_base: usize, entries: []const Entry, slot_map: *const std.AutoHashMap([32]u8, u64), image_blocks: u32) void {
    for (entries) |e| {
        if (e.kind != .file or e.layout != LayoutChunkBased) continue;
        if (e.trailing == 0) continue;
        const iloc = meta_base + @as(usize, @intCast(e.nid * 32));
        if (iloc + InodeCompact > meta.len) continue;
        const i_format = std.mem.readInt(u16, meta[iloc..][0..2], .little);
        const inode_size: usize = if ((i_format & 1) != 0) InodeExtended else InodeCompact;
        var chunk_start = iloc + inode_size;
        const rem = chunk_start % 8;
        if (rem != 0) chunk_start += 8 - rem;
        const nchunks = e.trailing / ChunkIndexSize;
        var i: usize = 0;
        while (i < nchunks) : (i += 1) {
            const off = chunk_start + i * ChunkIndexSize;
            if (off + ChunkIndexSize > meta.len) break;
            if (std.mem.readInt(u16, meta[off..][0..2], .little) == 0xffff) continue;
            const pos = i * ChunkSize;
            const slot = slotForOffset(e.blocks, e.size, pos, slot_map);
            if (slot == null) continue;
            const blocks_per_slot = ChunkSize / BlockSize;
            const start_blk = image_blocks + slot.? * blocks_per_slot;
            std.mem.writeInt(u16, meta[off..][0..2], @intCast(start_blk >> 32), .little);
            std.mem.writeInt(u16, meta[off + 2 ..][0..2], 0, .little);
            std.mem.writeInt(u32, meta[off + 4 ..][0..4], @truncate(start_blk), .little);
        }
    }
}

fn writeSuperblock(image: []u8, root_nid: u64, inos: u64, build_time: u64, blocks: u32, meta_blk: u32) void {
    var sb: [SbSize]u8 = undefined;
    @memset(&sb, 0);
    std.mem.writeInt(u32, sb[0..4], Magic, .little);
    sb[12] = 12; // blkszbits
    std.mem.writeInt(u16, sb[10..12], @intCast(root_nid), .little);
    std.mem.writeInt(u64, sb[16..24], inos, .little);
    std.mem.writeInt(u64, sb[24..32], build_time, .little);
    std.mem.writeInt(u32, sb[36..40], blocks, .little);
    std.mem.writeInt(u32, sb[40..44], meta_blk, .little);
    std.mem.writeInt(u32, sb[80..84], 0x4, .little); // FeatureIncompatChunkedFile
    @memcpy(image[SbOffset .. SbOffset + SbSize], &sb);
}

pub const Error = error{
    InodeNotFound,
    EmptyTree,
    LayoutFailed,
};
