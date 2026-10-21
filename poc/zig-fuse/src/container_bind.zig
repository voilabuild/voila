//! Rootless bind mounts into the FUSE rootfs via a private mount namespace.
const std = @import("std");
const run_cli_parse = @import("run_cli_parse.zig");
const posix_util = @import("posix_util.zig");

const MS_BIND: usize = 4096;
const MS_REC: usize = 16384;
const MS_RDONLY: usize = 1;
const MS_PRIVATE: usize = 1 << 18;
const CLONE_NEWNS: usize = 0x00020000;
const CLONE_NEWUSER: usize = 0x10000000;

extern "c" fn unshare(flags: c_int) c_int;
extern "c" fn mount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    filesystemtype: ?[*:0]const u8,
    mountflags: usize,
    data: ?*anyopaque,
) c_int;

pub fn applyInChild(mount_dir: []const u8, volumes: []const run_cli_parse.Volume) !void {
    if (unshare(@intCast(CLONE_NEWNS | CLONE_NEWUSER)) != 0) return error.UnshareFailed;
    writeUidMap();
    const mount_z = try allocZ(mount_dir);
    defer std.heap.page_allocator.free(mount_z);
    if (mount(mount_z, mount_z, null, MS_BIND | MS_REC, null) != 0) return error.BindMountFailed;
    if (volumes.len == 0) return;
    const slash_z: [*:0]const u8 = "/";
    _ = mount(null, slash_z, null, MS_REC | MS_PRIVATE, null);
    for (volumes) |vol| {
        const target = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, vol.container });
        defer std.heap.page_allocator.free(target);
        try ensureParent(target);
        const host_z = try allocZ(vol.host);
        defer std.heap.page_allocator.free(host_z);
        const target_z = try allocZ(target);
        defer std.heap.page_allocator.free(target_z);
        if (mount(host_z, target_z, null, MS_BIND | MS_REC, null) != 0) return error.BindMountFailed;
        if (vol.read_only) {
            _ = mount(null, target_z, null, MS_BIND | MS_REMOUNT | MS_RDONLY, null);
        }
    }
}

fn ensureParent(path: []const u8) !void {
    var i = path.len;
    while (i > 0) {
        if (path[i - 1] == '/') break;
        i -= 1;
    }
    if (i <= 1) return;
    const parent = path[0 .. i - 1];
    if (parent.len == 0) return;
    try posix_util.makePath(parent);
}

fn writeUidMap() void {
    const path = "/proc/self/uid_map";
    const data = "0 0 1\n";
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, data.ptr, data.len);
    const deny = "/proc/self/setgroups";
    const deny_z = std.heap.page_allocator.allocSentinel(u8, deny.len, 0) catch return;
    defer std.heap.page_allocator.free(deny_z);
    @memcpy(deny_z, deny);
    const dfd = std.c.open(deny_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (dfd >= 0) {
        defer _ = std.c.close(dfd);
        _ = std.c.write(dfd, "deny", 4);
    }
}

fn allocZ(s: []const u8) ![:0]const u8 {
    const out = try std.heap.page_allocator.allocSentinel(u8, s.len, 0);
    @memcpy(out, s);
    return out;
}

const MS_REMOUNT: usize = 32;

pub const Error = error{
    UnshareFailed,
    BindMountFailed,
};
