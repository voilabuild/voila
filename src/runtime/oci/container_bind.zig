//! Rootless bind mounts into the FUSE rootfs via a private mount namespace.
const std = @import("std");
const run_flags = @import("../run_flags.zig");
const posix_util = @import("sys").posix_util;
const fs = @import("sys").fs;

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

/// Quick check: unprivileged user + mount namespaces (no bind mounts).
pub fn probeUserNamespaces() bool {
    const host_uid = std.c.getuid();
    const host_gid = std.c.getgid();
    if (unshare(@intCast(CLONE_NEWUSER)) != 0) return false;
    if (!writeUidMapFor(host_uid)) return false;
    writeGidMapFor(host_gid);
    if (unshare(@intCast(CLONE_NEWNS)) != 0) return false;
    return true;
}

fn enterUserNamespace() bool {
    const host_uid = std.c.getuid();
    const host_gid = std.c.getgid();
    if (unshare(@intCast(CLONE_NEWUSER)) != 0) return false;
    if (!writeUidMapFor(host_uid)) return false;
    writeGidMapFor(host_gid);
    return true;
}

fn enterUserAndMountNs() bool {
    if (!enterUserNamespace()) return false;
    if (unshare(@intCast(CLONE_NEWNS)) != 0) return false;
    return true;
}

fn bindPrivateRoot(mount_dir: []const u8) bool {
    const mount_z = allocZ(mount_dir) catch return false;
    defer std.heap.page_allocator.free(mount_z);
    if (mount(mount_z, mount_z, null, MS_BIND | MS_REC, null) != 0) return false;
    const slash_z: [*:0]const u8 = "/";
    _ = mount(null, slash_z, null, MS_REC | MS_PRIVATE, null);
    return true;
}

/// User namespace only (keeps the host mount namespace — FUSE stays visible).
pub fn enterUserNamespaceOnly() bool {
    return enterUserNamespace();
}

/// Call in the FUSE worker before mounting when `-v` bind mounts are used.
pub fn setupMountNamespaceForWorker(mount_dir: []const u8) bool {
    if (!enterUserAndMountNs()) return false;
    return bindPrivateRoot(mount_dir);
}

pub fn applyVolumeBinds(mount_dir: []const u8, volumes: []const run_flags.Volume) bool {
    for (volumes) |vol| {
        const target = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, vol.container }) catch return false;
        defer std.heap.page_allocator.free(target);
        ensureParent(target) catch return false;
        ensureTarget(vol.host, target);
        const host_z = allocZ(vol.host) catch return false;
        defer std.heap.page_allocator.free(host_z);
        const target_z = allocZ(target) catch return false;
        defer std.heap.page_allocator.free(target_z);
        if (mount(host_z, target_z, null, MS_BIND | MS_REC, null) != 0) return false;
        if (vol.read_only) {
            _ = mount(null, target_z, null, MS_BIND | MS_REMOUNT | MS_RDONLY, null);
        }
    }
    return true;
}

/// User + mount namespace and optional bind mounts (legacy; prefer worker setup + applyVolumeBinds).
pub fn prepareExecEnvironment(mount_dir: []const u8, volumes: []const run_flags.Volume) bool {
    if (!setupMountNamespaceForWorker(mount_dir)) return false;
    return applyVolumeBinds(mount_dir, volumes);
}

/// Create a missing bind target of the host path's kind; on a read-only root it stays missing.
fn ensureTarget(host: []const u8, target: []const u8) void {
    if (posix_util.access(target)) return;
    const st = fs.lstat(host) catch return;
    if (st.kind == .dir) {
        fs.makePath(target) catch {};
    } else {
        fs.writeFile(target, "", 0o644) catch {};
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

pub fn writeGidMapFor(host_gid: std.c.uid_t) void {
    const deny = "/proc/self/setgroups";
    const deny_z = std.heap.page_allocator.allocSentinel(u8, deny.len, 0) catch return;
    defer std.heap.page_allocator.free(deny_z);
    @memcpy(deny_z, deny);
    const dfd = std.c.open(deny_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (dfd >= 0) {
        defer _ = std.c.close(dfd);
        _ = std.c.write(dfd, "deny", 4);
    }
    var data: [64]u8 = undefined;
    const data_slice = std.fmt.bufPrint(&data, "0 {d} 1\n", .{host_gid}) catch return;
    _ = writeProcMap("/proc/self/gid_map", data_slice);
}

pub fn writeUidMapFor(host_uid: std.c.uid_t) bool {
    var data: [64]u8 = undefined;
    const data_slice = std.fmt.bufPrint(&data, "0 {d} 1\n", .{host_uid}) catch return false;
    return writeProcMap("/proc/self/uid_map", data_slice);
}

fn writeProcMap(path: []const u8, data: []const u8) bool {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    const n = std.c.write(fd, data.ptr, data.len);
    return n == @as(@TypeOf(n), @intCast(data.len));
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
