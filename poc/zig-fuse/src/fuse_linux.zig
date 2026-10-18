const std = @import("std");
const posix_util = @import("posix_util.zig");
const fuse_vfs = @import("fuse_vfs.zig");
const fuse_libfuse = @import("fuse_libfuse.zig");

pub const Session = fuse_libfuse.Session;

pub fn canUseFuse() bool {
    return posix_util.access("/dev/fuse");
}

pub fn fuseMountOptions() []const u8 {
    if (std.os.linux.geteuid() == 0) return "ro,allow_other";
    return "ro";
}

pub fn mountAndServe(_: std.Io, allocator: std.mem.Allocator, vfs: *fuse_vfs.FuseVfs, mountpoint: []const u8) !void {
    try posix_util.makePath(mountpoint);
    try fuse_libfuse.mountAndServe(allocator, vfs, mountpoint, fuseMountOptions());
}

pub fn mountSession(allocator: std.mem.Allocator, mountpoint: []const u8, vfs: *fuse_vfs.FuseVfs) !Session {
    try posix_util.makePath(mountpoint);
    return fuse_libfuse.mountSession(allocator, mountpoint, vfs, fuseMountOptions());
}

pub fn serveSession(session: *Session) !void {
    try fuse_libfuse.serveSession(session);
}
