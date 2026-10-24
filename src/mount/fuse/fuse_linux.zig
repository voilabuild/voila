const std = @import("std");
const posix_util = @import("../../sys/posix_util.zig");
const fuse_vfs = @import("./fuse_vfs.zig");
const fuse_libfuse = @import("./fuse_libfuse.zig");

pub const Session = fuse_libfuse.Session;

const fuse_conf_path = "/etc/fuse.conf";

pub fn canUseFuse() bool {
    return posix_util.access("/dev/fuse");
}

/// True when `user_allow_other` is set in fuse.conf (uncommented), so libfuse may use `allow_other` as non-root.
pub fn fuseUserAllowOtherEnabled() bool {
    return fuseConfUserAllowOther(fuse_conf_path);
}

pub fn fuseConfUserAllowOther(path: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const data = posix_util.readFileAlloc(arena.allocator(), path, 64 * 1024) catch return false;
    return fuseConfUserAllowOtherFromBytes(data);
}

pub fn fuseConfUserAllowOtherFromBytes(data: []const u8) bool {
    var start: usize = 0;
    while (start < data.len) {
        var end = start;
        while (end < data.len and data[end] != '\n') end += 1;
        const line = std.mem.trim(u8, data[start..end], " \t\r");
        if (line.len == 0 or line[0] == '#') {
            start = end + 1;
            continue;
        }
        if (std.mem.eql(u8, line, "user_allow_other")) return true;
        start = end + 1;
    }
    return false;
}

/// Images are immutable, so the kernel may cache pages, entries, attributes and misses.
const cache_opts = "kernel_cache,entry_timeout=86400,attr_timeout=86400,negative_timeout=86400";

pub fn fuseMountOptions() []const u8 {
    if (std.os.linux.geteuid() == 0) return "ro,allow_other," ++ cache_opts;
    if (fuseUserAllowOtherEnabled()) return "ro,allow_other," ++ cache_opts;
    return "ro," ++ cache_opts;
}

pub fn printAllowOtherHint() void {
    if (std.os.linux.geteuid() == 0) return;
    if (fuseUserAllowOtherEnabled()) return;
    std.debug.print(
        "hint: add 'user_allow_other' to /etc/fuse.conf (or run install.sh) so container UIDs can use the FUSE rootfs without sudo\n",
        .{},
    );
}

pub fn mountAndServe(_: std.Io, allocator: std.mem.Allocator, vfs: *fuse_vfs.FuseVfs, mountpoint: []const u8) !void {
    try posix_util.makePath(mountpoint);
    printAllowOtherHint();
    try fuse_libfuse.mountAndServe(allocator, vfs, mountpoint, fuseMountOptions());
}

pub fn mountSession(allocator: std.mem.Allocator, mountpoint: []const u8, vfs: *fuse_vfs.FuseVfs) !Session {
    try posix_util.makePath(mountpoint);
    printAllowOtherHint();
    return fuse_libfuse.mountSession(allocator, mountpoint, vfs, fuseMountOptions());
}

pub fn serveSession(session: *Session) !void {
    try fuse_libfuse.serveSession(session);
}
