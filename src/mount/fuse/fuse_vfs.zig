const std = @import("std");
const vfs_mod = @import("./vfs.zig");
const voila_vfs = @import("./voila_vfs.zig");
const fuse_abi = @import("./fuse_abi.zig");

pub const FuseVfs = union(enum) {
    fixture: vfs_mod.Vfs,
    voila: voila_vfs.VoilaVfs,

    pub fn deinit(self: *FuseVfs) void {
        switch (self.*) {
            .fixture => |*v| v.deinit(),
            .voila => |*v| v.deinit(),
        }
    }

    pub fn inoFromPath(self: *FuseVfs, path: []const u8) ?u64 {
        return switch (self.*) {
            .fixture => |*v| v.inoFromPath(path),
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.inoFromPath(path);
            },
        };
    }

    pub fn lookup(self: *FuseVfs, parent: u64, name: []const u8) ?u64 {
        return switch (self.*) {
            .fixture => |*v| v.lookup(parent, name),
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.lookup(parent, name);
            },
        };
    }

    pub fn attr(self: *FuseVfs, ino: u64) ?fuse_abi.Attr {
        return switch (self.*) {
            .fixture => |*v| v.attr(ino),
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.attr(ino);
            },
        };
    }

    pub fn readlink(self: *FuseVfs, ino: u64) ?[]const u8 {
        return switch (self.*) {
            .fixture => |*v| v.readlink(ino),
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.readlink(ino);
            },
        };
    }

    pub fn isDir(self: *FuseVfs, ino: u64) bool {
        return switch (self.*) {
            .fixture => ino == @import("core").constants.root_ino,
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.isDir(ino);
            },
        };
    }

    pub fn isFile(self: *FuseVfs, ino: u64) bool {
        return switch (self.*) {
            .fixture => ino == @import("core").constants.file_ino,
            .voila => |*v| blk: {
                v.lock();
                defer v.unlock();
                break :blk v.isFile(ino);
            },
        };
    }

    pub fn readdirEntry(self: *FuseVfs, dir_ino: u64, index: usize) ?struct { name: []const u8, ino: u64, typ: u32 } {
        return switch (self.*) {
            .fixture => |*v| {
                if (dir_ino != @import("core").constants.root_ino) return null;
                const ent = v.readdirEntry(index) orelse return null;
                return .{ .name = ent.name, .ino = ent.ino, .typ = ent.typ };
            },
            .voila => |*v| {
                v.lock();
                defer v.unlock();
                const ent = v.readdirEntry(dir_ino, index) orelse return null;
                return .{ .name = ent.name, .ino = ent.ino, .typ = ent.typ };
            },
        };
    }

    pub fn preloadAllChunks(self: *FuseVfs, io: std.Io) !void {
        switch (self.*) {
            .fixture => |*v| try v.preloadAllChunks(io),
            .voila => |*v| try v.preloadAllChunks(io),
        }
    }

    pub fn readFuse(self: *FuseVfs, ino: u64, buf: []u8, off: u64) usize {
        return switch (self.*) {
            .fixture => |*v| v.readFuse(ino, buf, off),
            .voila => |*v| v.readFuseShared(ino, buf, off),
        };
    }
};
