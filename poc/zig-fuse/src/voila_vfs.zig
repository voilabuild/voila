const std = @import("std");
const fuse_abi = @import("fuse_abi.zig");
const voila_index = @import("voila_index.zig");
const voila_store = @import("voila_store.zig");
const posix_util = @import("posix_util.zig");

pub const DirEnt = struct {
    name: []const u8,
    ino: u64,
    typ: u32,
};

pub const VoilaVfs = struct {
    index: voila_index.Index,
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
        var readdir_by_ino: std.AutoHashMap(u64, []DirEnt) = .init(allocator);
        var dit = index.dirs.iterator();
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
                    .typ = entryType(&index, child),
                };
            }
            try readdir_by_ino.put(d.key_ptr.*, list);
            names.deinit(allocator);
        }
        return .{
            .index = index,
            .readdir_by_ino = readdir_by_ino,
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
        self.index.deinit();
    }

    pub fn rootIno(self: *const VoilaVfs) u64 {
        return self.index.root_ino;
    }

    pub fn lookup(self: *const VoilaVfs, parent: u64, name: []const u8) ?u64 {
        if (std.mem.eql(u8, name, ".")) return parent;
        if (std.mem.eql(u8, name, "..")) return if (parent == self.index.root_ino) parent else null;
        const dir = self.index.dirs.get(parent) orelse return null;
        return dir.entries.get(name);
    }

    pub fn inoFromPath(self: *const VoilaVfs, path: []const u8) ?u64 {
        if (std.mem.eql(u8, path, "/")) return self.index.root_ino;
        if (path.len == 0 or path[0] != '/') return null;
        var ino = self.index.root_ino;
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

    pub fn isDir(self: *const VoilaVfs, ino: u64) bool {
        return self.index.dirs.contains(ino);
    }

    pub fn isFile(self: *const VoilaVfs, ino: u64) bool {
        return self.index.files.contains(ino);
    }

    pub fn attr(self: *const VoilaVfs, ino: u64) ?fuse_abi.Attr {
        const mtime_sec: u64 = 0;
        const mtime_nsec: u32 = 0;
        if (self.index.dirs.get(ino)) |d| {
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
        if (self.index.files.get(ino)) |f| {
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
        if (self.index.symlinks.get(ino)) |l| {
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
        if (self.index.devices.get(ino)) |dv| {
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

    pub fn readlink(self: *const VoilaVfs, ino: u64) ?[]const u8 {
        const l = self.index.symlinks.get(ino) orelse return null;
        return l.target;
    }

    pub fn readdirEntry(self: *const VoilaVfs, dir_ino: u64, index: usize) ?DirEnt {
        const list = self.readdir_by_ino.get(dir_ino) orelse return null;
        if (index >= list.len) return null;
        return list[index];
    }

    pub fn preloadAllChunks(_: *VoilaVfs, _: std.Io) !void {}

    pub fn readFuse(self: *VoilaVfs, ino: u64, buf: []u8, off: u64) usize {
        const file = self.index.files.get(ino) orelse return 0;
        if (off >= file.size) return 0;
        const max = @min(buf.len, @as(usize, @intCast(file.size - off)));
        @memset(buf[0..max], 0);
        var done: usize = 0;
        var pos = off;
        while (done < max) {
            const n = self.readFileOnce(file, buf[done..max], pos) catch break;
            if (n == 0) break;
            done += n;
            pos += n;
        }
        return done;
    }

    fn readFileOnce(self: *VoilaVfs, file: voila_index.File, buf: []u8, off: u64) !usize {
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

    fn getChunk(self: *VoilaVfs, hex: []const u8, algo: i32) ![]const u8 {
        if (self.chunk_cache.get(hex)) |c| return c;
        const owned = try voila_store.loadChunkRaw(self.allocator, self.index.voila_root, hex, algo);
        const key = try self.allocator.dupe(u8, hex);
        try self.chunk_cache.put(key, owned);
        return owned;
    }
};

fn entryType(index: *const voila_index.Index, ino: u64) u32 {
    if (index.dirs.contains(ino)) return fuse_abi.DT_DIR;
    if (index.files.contains(ino)) return fuse_abi.DT_REG;
    if (index.symlinks.contains(ino)) return fuse_abi.DT_LNK;
    return fuse_abi.DT_REG;
}

fn mkdev(major: u32, minor: u32) u32 {
    return (minor & 0xff) | (major << 8) | ((minor & ~@as(u32, 0xff)) << 12);
}
