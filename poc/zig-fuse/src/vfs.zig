const std = @import("std");
const constants = @import("constants.zig");
const fixture = @import("fixture.zig");
const fuse_abi = @import("fuse_abi.zig");
const read_walker = @import("read_walker.zig");

pub const Vfs = struct {
    tree: fixture.Tree,
    walker: read_walker.Walker,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator, fixture_dir: []const u8) !Vfs {
        var tree = try fixture.Tree.load(allocator, fixture_dir);
        errdefer tree.deinit();

        const file = tree.file orelse return error.BadTree;
        var walker = try read_walker.Walker.init(
            allocator,
            tree.fixture_dir,
            file.size,
            file.chunk_names,
        );
        errdefer walker.deinit();

        return .{
            .tree = tree,
            .walker = walker,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Vfs) void {
        self.walker.deinit();
        self.tree.deinit();
    }

    pub fn inoFromPath(self: *const Vfs, path: []const u8) ?u64 {
        if (std.mem.eql(u8, path, "/")) return constants.root_ino;
        const file = self.tree.file orelse return null;
        const link = self.tree.symlink orelse return null;
        if (path.len == file.name.len + 1 and path[0] == '/' and std.mem.eql(u8, path[1..], file.name)) {
            return constants.file_ino;
        }
        if (path.len == link.name.len + 1 and path[0] == '/' and std.mem.eql(u8, path[1..], link.name)) {
            return constants.link_ino;
        }
        return null;
    }

    pub fn lookup(self: *const Vfs, parent: u64, name: []const u8) ?u64 {
        if (parent == constants.root_ino and (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))) {
            return constants.root_ino;
        }
        if (parent != constants.root_ino) return null;
        const file = self.tree.file orelse return null;
        const link = self.tree.symlink orelse return null;
        if (std.mem.eql(u8, name, file.name)) return constants.file_ino;
        if (std.mem.eql(u8, name, link.name)) return constants.link_ino;
        return null;
    }

    pub fn attr(self: *const Vfs, ino: u64) ?fuse_abi.Attr {
        const now: u64 = 1;
        const base = fuse_abi.Attr{
            .ino = ino,
            .size = 0,
            .blocks = 0,
            .atime = now,
            .mtime = now,
            .ctime = now,
            .atime_nsec = 0,
            .mtime_nsec = 0,
            .ctime_nsec = 0,
            .mode = 0,
            .nlink = 1,
            .uid = 0,
            .gid = 0,
            .rdev = 0,
            .blksize = 4096,
            ._pad = 0,
        };
        switch (ino) {
            constants.root_ino => {
                var a = base;
                a.mode = 0o040755;
                a.nlink = 2;
                return a;
            },
            constants.file_ino => {
                const file = self.tree.file orelse return null;
                var a = base;
                a.mode = 0o100644;
                a.size = file.size;
                a.blocks = (file.size + 511) / 512;
                return a;
            },
            constants.link_ino => {
                const link = self.tree.symlink orelse return null;
                var a = base;
                a.mode = 0o120777;
                a.size = @intCast(link.target.len);
                return a;
            },
            else => return null,
        }
    }

    pub fn readlink(self: *const Vfs, ino: u64) ?[]const u8 {
        if (ino != constants.link_ino) return null;
        const link = self.tree.symlink orelse return null;
        return link.target;
    }

    pub fn readdirEntry(self: *const Vfs, index: usize) ?struct { name: []const u8, ino: u64, typ: u32 } {
        const file = self.tree.file orelse return null;
        const link = self.tree.symlink orelse return null;
        return switch (index) {
            0 => .{ .name = file.name, .ino = constants.file_ino, .typ = fuse_abi.DT_REG },
            1 => .{ .name = link.name, .ino = constants.link_ino, .typ = fuse_abi.DT_LNK },
            else => null,
        };
    }

    pub fn preloadAllChunks(self: *Vfs, io: std.Io) !void {
        for (0..self.walker.chunk_names.len) |slot| {
            try self.walker.ensureChunkLoaded(io, slot);
        }
    }

    /// FUSE READ handler: chunks must be preloaded on the main thread (no io / alloc on serve thread).
    pub fn readFuse(self: *Vfs, ino: u64, buf: []u8, off: u64) usize {
        if (ino != constants.file_ino) return 0;
        const file = self.tree.file orelse return 0;
        if (off >= file.size) return 0;
        const max = @min(buf.len, @as(usize, @intCast(file.size - off)));
        self.walker.readSync(buf[0..max], off);
        return max;
    }

    pub fn read(self: *Vfs, io: std.Io, ino: u64, buf: []u8, off: u64) !usize {
        if (ino != constants.file_ino) return 0;
        const file = self.tree.file orelse return 0;
        if (off >= file.size) return 0;
        const max = @min(buf.len, @as(usize, @intCast(file.size - off)));
        try self.walker.read(io, buf[0..max], off);
        return max;
    }
};
