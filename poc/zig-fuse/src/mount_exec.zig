//! Resolve executables and wait for mounts without touching the FUSE tree from
//! the same process that serves it (access/stat on the mount deadlocks).

const std = @import("std");
const fuse_vfs_mod = @import("fuse_vfs.zig");
const posix_util = @import("posix_util.zig");

const default_path_dirs = [_][]const u8{
    "/usr/local/sbin",
    "/usr/local/bin",
    "/usr/sbin",
    "/usr/bin",
    "/sbin",
    "/bin",
};

pub fn waitMountListed(mount_dir: []const u8, io: std.Io) !void {
    for (0..30_000) |_| {
        if (mountListed(mount_dir)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.MountNotReady;
}

fn nextField(line: []const u8, start: usize) ?struct { value: []const u8, end: usize } {
    var i = start;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i >= line.len) return null;
    var j = i;
    while (j < line.len and line[j] != ' ') j += 1;
    return .{ .value = line[i..j], .end = j };
}

fn mountListed(mount_dir: []const u8) bool {
    const data = posix_util.readFileAlloc(std.heap.page_allocator, "/proc/mounts", 256 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);
    var start: usize = 0;
    while (start < data.len) {
        var end = start;
        while (end < data.len and data[end] != '\n') end += 1;
        const line = data[start..end];
        start = end + 1;
        const mnt = nextField(line, 0) orelse continue;
        const mnt_pt = nextField(line, mnt.end) orelse continue;
        const fstype = nextField(line, mnt_pt.end) orelse continue;
        if (!std.mem.eql(u8, mnt_pt.value, mount_dir)) continue;
        if (!std.mem.eql(u8, fstype.value, "fuse")) continue;
        return true;
    }
    return false;
}

/// Image-root path (e.g. `/bin/sh`) for argv0, verified via in-memory VFS.
pub fn resolveArgv0VfsPath(allocator: std.mem.Allocator, vfs: *fuse_vfs_mod.FuseVfs, argv0: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        const vfs_path = if (std.mem.startsWith(u8, argv0, "/"))
            try allocator.dupe(u8, argv0)
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{argv0});
        if (!executableOnVfs(vfs, vfs_path)) {
            allocator.free(vfs_path);
            return error.ExecNotFound;
        }
        return vfs_path;
    }
    for (default_path_dirs) |dir| {
        const vfs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, argv0 });
        if (executableOnVfs(vfs, vfs_path)) return vfs_path;
        allocator.free(vfs_path);
    }
    return error.ExecNotFound;
}

pub fn hostPathForVfsExec(allocator: std.mem.Allocator, mount_dir: []const u8, vfs_exec: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ mount_dir, vfs_exec });
}

fn executableOnVfs(vfs: *fuse_vfs_mod.FuseVfs, vfs_path: []const u8) bool {
    const ino = vfs.inoFromPath(vfs_path) orelse return false;
    if (vfs.isFile(ino)) return true;
    // Alpine and others expose /bin/sh as a symlink; execve resolves it on the mount.
    return vfs.readlink(ino) != null;
}

pub const Error = error{
    MountNotReady,
    ExecNotFound,
};
