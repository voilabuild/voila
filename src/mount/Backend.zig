const std = @import("std");
const fuse_linux = @import("fuse/fuse_linux.zig");
const fuse_vfs = @import("fuse/fuse_vfs.zig");

/// Mount backend that serves a read-only filesystem at a mountpoint.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        mount_and_serve: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, mountpoint: []const u8) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn mountAndServe(self: Backend, io: std.Io, allocator: std.mem.Allocator, mountpoint: []const u8) !void {
        return self.vtable.mount_and_serve(self.ptr, io, allocator, mountpoint);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.ptr);
    }
};

/// FUSE-backed mount backend (today's production path).
pub const Fuse = struct {
    vfs: *fuse_vfs.FuseVfs,

    pub fn backend(self: *Fuse) Backend {
        return .{ .ptr = self, .vtable = &fuse_vtable };
    }

    const fuse_vtable = Backend.VTable{
        .mount_and_serve = fuseMountAndServe,
        .deinit = fuseDeinit,
    };

    fn fuseMountAndServe(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, mountpoint: []const u8) !void {
        const self: *Fuse = @ptrCast(@alignCast(ptr));
        return fuse_linux.mountAndServe(io, allocator, self.vfs, mountpoint);
    }

    fn fuseDeinit(_: *anyopaque) void {}
};

pub fn fuse(vfs: *fuse_vfs.FuseVfs) Fuse {
    return .{ .vfs = vfs };
}
