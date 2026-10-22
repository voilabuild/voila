const std = @import("std");
const fuse_abi = @import("./fuse_abi.zig");
const voila_index = @import("../../core/voila_index.zig");
const voila_tree = @import("../../core/voila_tree.zig");
const voila_store = @import("../../store/voila_store.zig");
const voila_chunk_load = @import("../../store/voila_chunk_load.zig");
const hub = @import("../../registry/voila_registry_hub.zig");
const voila_resolve = @import("../../runtime/voila_resolve.zig");
const voila_chunk_index = @import("../../store/voila_chunk_index.zig");
const voila_manifest_proto = @import("../../codec/voila_manifest_proto.zig");
const posix_util = @import("../../sys/posix_util.zig");

pub const DirEnt = struct {
    name: []const u8,
    ino: u64,
    typ: u32,
};

pub const VoilaVfs = struct {
    backend: union(enum) {
        indexed: voila_index.Index,
        lazy_tree: voila_tree.Tree,
    },
    readdir_by_ino: std.AutoHashMap(u64, []DirEnt),
    chunk_cache: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, index_json_path: []const u8) !VoilaVfs {
        const json_bytes = try posix_util.readFileAlloc(allocator, index_json_path, 256 * 1024 * 1024);
        defer allocator.free(json_bytes);
        const index = try voila_index.Index.parse(allocator, json_bytes);
        return initFromIndex(allocator, index);
    }

    pub fn initFromIndex(allocator: std.mem.Allocator, index: voila_index.Index) !VoilaVfs {
        var self: VoilaVfs = .{
            .backend = .{ .indexed = index },
            .readdir_by_ino = .init(allocator),
            .chunk_cache = .init(allocator),
            .allocator = allocator,
        };
        var dit = self.backend.indexed.dirs.iterator();
        while (dit.next()) |d| {
            var names: std.ArrayList([]const u8) = .empty;
            var eit = d.value_ptr.entries.keyIterator();
            while (eit.next()) |name| {
                try names.append(allocator, name.*);
            }
            std.sort.block([]const u8, names.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            const list = try allocator.alloc(DirEnt, names.items.len);
            for (names.items, 0..) |name, i| {
                const child = d.value_ptr.entries.get(name) orelse return error.BadIndex;
                list[i] = .{
                    .name = name,
                    .ino = child,
                    .typ = entryTypeIndexed(&index, child),
                };
            }
            try self.readdir_by_ino.put(d.key_ptr.*, list);
            names.deinit(allocator);
        }
        return self;
    }

    pub fn initFromTree(allocator: std.mem.Allocator, tree: voila_tree.Tree) VoilaVfs {
        return .{
            .backend = .{ .lazy_tree = tree },
            .readdir_by_ino = .init(allocator),
            .chunk_cache = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VoilaVfs) void {
        var cit = self.chunk_cache.iterator();
        while (cit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.chunk_cache.deinit();
        var rit = self.readdir_by_ino.iterator();
        while (rit.next()) |e| self.allocator.free(e.value_ptr.*);
        self.readdir_by_ino.deinit();
        switch (self.backend) {
            .indexed => |*idx| idx.deinit(),
            .lazy_tree => |*t| t.deinit(),
        }
    }

    fn voilaRoot(self: *const VoilaVfs) []const u8 {
        return switch (self.backend) {
            .indexed => |*idx| idx.voila_root,
            .lazy_tree => |*t| t.voila_root,
        };
    }

    pub fn rootIno(self: *const VoilaVfs) u64 {
        return switch (self.backend) {
            .indexed => |*idx| idx.root_ino,
            .lazy_tree => |*t| t.root_ino,
        };
    }

    pub fn lookup(self: *VoilaVfs, parent: u64, name: []const u8) ?u64 {
        if (std.mem.eql(u8, name, ".")) return parent;
        const root = self.rootIno();
        if (std.mem.eql(u8, name, "..")) return if (parent == root) parent else null;
        return switch (self.backend) {
            .indexed => |*idx| {
                const dir = idx.dirs.get(parent) orelse return null;
                return dir.entries.get(name);
            },
            .lazy_tree => |*tree| {
                tree.ensureInode(parent) catch return null;
                const dir = tree.dir_by_inode.get(parent) orelse return null;
                const child = dir.entries.get(name) orelse return null;
                tree.ensureInode(child) catch return null;
                return child;
            },
        };
    }

    pub fn inoFromPath(self: *VoilaVfs, path: []const u8) ?u64 {
        if (std.mem.eql(u8, path, "/")) return self.rootIno();
        if (path.len == 0 or path[0] != '/') return null;
        var ino = self.rootIno();
        var rest = path[1..];
        while (rest.len > 0) {
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const component = rest[0..(slash orelse rest.len)];
            rest = if (slash) |s| rest[s + 1 ..] else "";
            if (component.len == 0) continue;
            ino = self.lookup(ino, component) orelse return null;
        }
        return ino;
    }

    pub fn isDir(self: *VoilaVfs, ino: u64) bool {
        return switch (self.backend) {
            .indexed => |*idx| idx.dirs.contains(ino),
            .lazy_tree => |*tree| {
                tree.ensureInode(ino) catch return false;
                return tree.dir_by_inode.contains(ino);
            },
        };
    }

    pub fn isFile(self: *VoilaVfs, ino: u64) bool {
        return switch (self.backend) {
            .indexed => |*idx| idx.files.contains(ino),
            .lazy_tree => |*tree| {
                tree.ensureInode(ino) catch return false;
                return tree.file_by_inode.contains(ino);
            },
        };
    }

    pub fn attr(self: *VoilaVfs, ino: u64) ?fuse_abi.Attr {
        const mtime_sec: u64 = 0;
        const mtime_nsec: u32 = 0;
        return switch (self.backend) {
            .indexed => |*idx| attrFromIndex(idx, ino, mtime_sec, mtime_nsec),
            .lazy_tree => |*tree| {
                tree.ensureInode(ino) catch return null;
                return attrFromTree(tree, ino, mtime_sec, mtime_nsec);
            },
        };
    }

    pub fn readlink(self: *VoilaVfs, ino: u64) ?[]const u8 {
        return switch (self.backend) {
            .indexed => |*idx| {
                const l = idx.symlinks.get(ino) orelse return null;
                return l.target;
            },
            .lazy_tree => |*tree| {
                tree.ensureInode(ino) catch return null;
                const l = tree.symlink_by_inode.get(ino) orelse return null;
                return l.target;
            },
        };
    }

    fn ensureReaddirCache(self: *VoilaVfs, dir_ino: u64) !void {
        if (self.readdir_by_ino.contains(dir_ino)) return;
        switch (self.backend) {
            .indexed => return,
            .lazy_tree => |*tree| {
                tree.ensureInode(dir_ino) catch return;
                const d = tree.dir_by_inode.get(dir_ino) orelse return;
                var names: std.ArrayList([]const u8) = .empty;
                defer names.deinit(self.allocator);
                var it = d.entries.keyIterator();
                while (it.next()) |name| {
                    try names.append(self.allocator, name.*);
                }
                std.sort.block([]const u8, names.items, {}, struct {
                    fn less(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.less);
                const list = try self.allocator.alloc(DirEnt, names.items.len);
                for (names.items, 0..) |name, i| {
                    const child = d.entries.get(name) orelse continue;
                    list[i] = .{
                        .name = name,
                        .ino = child,
                        .typ = entryTypeTree(tree, child),
                    };
                }
                try self.readdir_by_ino.put(dir_ino, list);
            },
        }
    }

    pub fn readdirEntry(self: *VoilaVfs, dir_ino: u64, index: usize) ?DirEnt {
        self.ensureReaddirCache(dir_ino) catch return null;
        const list = self.readdir_by_ino.get(dir_ino) orelse return null;
        if (index >= list.len) return null;
        return list[index];
    }

    pub fn preloadAllChunks(_: *VoilaVfs, _: std.Io) !void {}

    pub fn readFuse(self: *VoilaVfs, ino: u64, buf: []u8, off: u64) usize {
        return switch (self.backend) {
            .indexed => |*idx| {
                const file = idx.files.get(ino) orelse return 0;
                if (off >= file.size) return 0;
                const max = @min(buf.len, @as(usize, @intCast(file.size - off)));
                @memset(buf[0..max], 0);
                var done: usize = 0;
                var pos = off;
                while (done < max) {
                    const n = self.readFileOnceIndexed(file, buf[done..max], pos) catch break;
                    if (n == 0) break;
                    done += n;
                    pos += n;
                }
                return done;
            },
            .lazy_tree => |*tree| {
                tree.ensureInode(ino) catch return 0;
                const file = tree.file_by_inode.get(ino) orelse return 0;
                if (off >= file.size) return 0;
                const max = @min(buf.len, @as(usize, @intCast(file.size - off)));
                @memset(buf[0..max], 0);
                var done: usize = 0;
                var pos = off;
                while (done < max) {
                    const n = self.readFileOnceTree(file, buf[done..max], pos) catch break;
                    if (n == 0) break;
                    done += n;
                    pos += n;
                }
                return done;
            },
        };
    }

    fn readFileOnceIndexed(self: *VoilaVfs, file: voila_index.File, buf: []u8, off: u64) !usize {
        if (off >= file.size) return 0;
        const goal = @min(buf.len, @as(usize, @intCast(file.size - off)));
        var filled: usize = 0;
        var cursor = off;
        for (file.blocks) |b| {
            const block_end = b.offset + b.logical_len;
            if (cursor >= block_end) continue;
            if (cursor < b.offset) {
                const hole = @min(@as(usize, @intCast(b.offset - cursor)), goal - filled);
                filled += hole;
                cursor += hole;
                if (filled >= goal) return filled;
            }
            if (b.chunk_hex.len == 0) {
                const zeros = @min(@as(usize, @intCast(block_end - cursor)), goal - filled);
                filled += zeros;
                cursor += zeros;
                continue;
            }
            const chunk = self.getChunk(b.chunk_hex, b.algo) catch return error.ReadFailed;
            const chunk_off: usize = @intCast(cursor - b.offset);
            const avail = @min(chunk.len - chunk_off, goal - filled);
            @memcpy(buf[filled..][0..avail], chunk[chunk_off..][0..avail]);
            filled += avail;
            cursor += avail;
            if (filled >= goal) return filled;
        }
        if (cursor < file.size and filled < goal) {
            const tail = @min(@as(usize, @intCast(file.size - cursor)), goal - filled);
            filled += tail;
        }
        return filled;
    }

    fn readFileOnceTree(self: *VoilaVfs, file: voila_manifest_proto.FileMsg, buf: []u8, off: u64) !usize {
        if (off >= file.size) return 0;
        const goal = @min(buf.len, @as(usize, @intCast(file.size - off)));
        var filled: usize = 0;
        var cursor = off;
        const root = self.voilaRoot();
        for (file.blocks) |b| {
            const block_end = b.offset + b.logical_len;
            if (cursor >= block_end) continue;
            if (cursor < b.offset) {
                const hole = @min(@as(usize, @intCast(b.offset - cursor)), goal - filled);
                filled += hole;
                cursor += hole;
                if (filled >= goal) return filled;
            }
            if (b.chunk_id.len != 32) {
                const zeros = @min(@as(usize, @intCast(block_end - cursor)), goal - filled);
                filled += zeros;
                cursor += zeros;
                continue;
            }
            const hex = try voila_resolve.chunkIdToHex(self.allocator, b.chunk_id);
            defer self.allocator.free(hex);
            const algo = voila_chunk_index.compAlgoForChunk(root, b.chunk_id) catch voila_store.AlgoRaw;
            const chunk = self.getChunk(hex, algo) catch return error.ReadFailed;
            const chunk_off: usize = @intCast(cursor - b.offset);
            const avail = @min(chunk.len - chunk_off, goal - filled);
            @memcpy(buf[filled..][0..avail], chunk[chunk_off..][0..avail]);
            filled += avail;
            cursor += avail;
            if (filled >= goal) return filled;
        }
        if (cursor < file.size and filled < goal) {
            const tail = @min(@as(usize, @intCast(file.size - cursor)), goal - filled);
            filled += tail;
        }
        return filled;
    }

    fn getChunk(self: *VoilaVfs, hex: []const u8, algo: i32) ![]const u8 {
        if (self.chunk_cache.get(hex)) |c| return c;
        const owned = try voila_chunk_load.loadChunkRaw(hub.g_io, self.allocator, self.voilaRoot(), hex, algo);
        const key = try self.allocator.dupe(u8, hex);
        try self.chunk_cache.put(key, owned);
        return owned;
    }
};

fn attrFromIndex(idx: *voila_index.Index, ino: u64, mtime_sec: u64, mtime_nsec: u32) ?fuse_abi.Attr {
    if (idx.dirs.get(ino)) |d| {
        const sec = d.mtime_ns / 1_000_000_000;
        const nsec: u32 = @intCast(d.mtime_ns % 1_000_000_000);
        return fuse_abi.Attr{
            .ino = ino,
            .size = 0,
            .blocks = 0,
            .atime = sec,
            .mtime = sec,
            .ctime = sec,
            .atime_nsec = nsec,
            .mtime_nsec = nsec,
            .ctime_nsec = nsec,
            .mode = 0o040000 | (d.mode & 0o7777),
            .nlink = 2,
            .uid = d.uid,
            .gid = d.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (idx.files.get(ino)) |f| {
        const sec = f.mtime_ns / 1_000_000_000;
        const nsec: u32 = @intCast(f.mtime_ns % 1_000_000_000);
        return fuse_abi.Attr{
            .ino = ino,
            .size = f.size,
            .blocks = (f.size + 511) / 512,
            .atime = sec,
            .mtime = sec,
            .ctime = sec,
            .atime_nsec = nsec,
            .mtime_nsec = nsec,
            .ctime_nsec = nsec,
            .mode = 0o100000 | (f.mode & 0o7777),
            .nlink = f.nlink,
            .uid = f.uid,
            .gid = f.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (idx.symlinks.get(ino)) |l| {
        return fuse_abi.Attr{
            .ino = ino,
            .size = @intCast(l.target.len),
            .blocks = 0,
            .atime = mtime_sec,
            .mtime = mtime_sec,
            .ctime = mtime_sec,
            .atime_nsec = mtime_nsec,
            .mtime_nsec = mtime_nsec,
            .ctime_nsec = mtime_nsec,
            .mode = 0o120000 | 0o777,
            .nlink = 1,
            .uid = l.uid,
            .gid = l.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (idx.devices.get(ino)) |dv| {
        const rdev = mkdev(dv.rdev_major, dv.rdev_minor);
        const ifmt: u32 = if (dv.is_char) 0o020000 else 0o060000;
        return fuse_abi.Attr{
            .ino = ino,
            .size = 0,
            .blocks = 0,
            .atime = mtime_sec,
            .mtime = mtime_sec,
            .ctime = mtime_sec,
            .atime_nsec = mtime_nsec,
            .mtime_nsec = mtime_nsec,
            .ctime_nsec = mtime_nsec,
            .mode = ifmt | (dv.mode & 0o7777),
            .nlink = 1,
            .uid = dv.uid,
            .gid = dv.gid,
            .rdev = rdev,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    return null;
}

fn attrFromTree(tree: *voila_tree.Tree, ino: u64, mtime_sec: u64, mtime_nsec: u32) ?fuse_abi.Attr {
    if (tree.dir_by_inode.get(ino)) |d| {
        const sec = d.mtime_ns / 1_000_000_000;
        const nsec: u32 = @intCast(d.mtime_ns % 1_000_000_000);
        return fuse_abi.Attr{
            .ino = ino,
            .size = 0,
            .blocks = 0,
            .atime = sec,
            .mtime = sec,
            .ctime = sec,
            .atime_nsec = nsec,
            .mtime_nsec = nsec,
            .ctime_nsec = nsec,
            .mode = 0o040000 | (d.mode & 0o7777),
            .nlink = 2,
            .uid = d.uid,
            .gid = d.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (tree.file_by_inode.get(ino)) |f| {
        const sec = f.mtime_ns / 1_000_000_000;
        const nsec: u32 = @intCast(f.mtime_ns % 1_000_000_000);
        return fuse_abi.Attr{
            .ino = ino,
            .size = f.size,
            .blocks = (f.size + 511) / 512,
            .atime = sec,
            .mtime = sec,
            .ctime = sec,
            .atime_nsec = nsec,
            .mtime_nsec = nsec,
            .ctime_nsec = nsec,
            .mode = 0o100000 | (f.mode & 0o7777),
            .nlink = f.nlink,
            .uid = f.uid,
            .gid = f.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (tree.symlink_by_inode.get(ino)) |l| {
        return fuse_abi.Attr{
            .ino = ino,
            .size = @intCast(l.target.len),
            .blocks = 0,
            .atime = mtime_sec,
            .mtime = mtime_sec,
            .ctime = mtime_sec,
            .atime_nsec = mtime_nsec,
            .mtime_nsec = mtime_nsec,
            .ctime_nsec = mtime_nsec,
            .mode = 0o120000 | 0o777,
            .nlink = 1,
            .uid = l.uid,
            .gid = l.gid,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    if (tree.device_by_inode.get(ino)) |dv| {
        const rdev = mkdev(dv.rdev_major, dv.rdev_minor);
        const ifmt: u32 = if (dv.is_char) 0o020000 else 0o060000;
        return fuse_abi.Attr{
            .ino = ino,
            .size = 0,
            .blocks = 0,
            .atime = mtime_sec,
            .mtime = mtime_sec,
            .ctime = mtime_sec,
            .atime_nsec = mtime_nsec,
            .mtime_nsec = mtime_nsec,
            .ctime_nsec = mtime_nsec,
            .mode = ifmt | (dv.mode & 0o7777),
            .nlink = 1,
            .uid = dv.uid,
            .gid = dv.gid,
            .rdev = rdev,
            .blksize = 4096,
            ._pad = 0,
        };
    }
    return null;
}

fn entryTypeIndexed(index: *const voila_index.Index, ino: u64) u32 {
    if (index.dirs.contains(ino)) return fuse_abi.DT_DIR;
    if (index.files.contains(ino)) return fuse_abi.DT_REG;
    if (index.symlinks.contains(ino)) return fuse_abi.DT_LNK;
    return fuse_abi.DT_REG;
}

fn entryTypeTree(tree: *const voila_tree.Tree, ino: u64) u32 {
    if (tree.dir_by_inode.contains(ino)) return fuse_abi.DT_DIR;
    if (tree.file_by_inode.contains(ino)) return fuse_abi.DT_REG;
    if (tree.symlink_by_inode.contains(ino)) return fuse_abi.DT_LNK;
    return fuse_abi.DT_REG;
}

fn mkdev(major: u32, minor: u32) u32 {
    return (minor & 0xff) | (major << 8) | ((minor & ~@as(u32, 0xff)) << 12);
}
