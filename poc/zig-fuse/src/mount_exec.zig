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

/// Wait until the mount root is readable in this process (safe outside the FUSE server).
pub fn waitMountRootReady(mount_dir: []const u8, io: std.Io) !void {
    try waitMountListed(mount_dir, io);
    for (0..30_000) |_| {
        if (!posix_util.access(mount_dir)) {
            try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
            continue;
        }
        const bin = std.fmt.allocPrint(std.heap.page_allocator, "{s}/bin", .{mount_dir}) catch continue;
        defer std.heap.page_allocator.free(bin);
        if (posix_util.access(bin)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.MountNotReady;
}

/// Wait until a path under the mount is visible in this process (safe outside the FUSE server).
pub fn waitHostPathReady(host_path: []const u8, io: std.Io) !void {
    for (0..30_000) |_| {
        if (posix_util.access(host_path)) return;
        try io.sleep(std.Io.Duration.fromMilliseconds(1), .awake);
    }
    return error.ExecNotFound;
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

const interpreter_candidates = [_][]const u8{
    "/lib/ld-musl-x86_64.so.1",
    "/lib64/ld-linux-x86-64.so.2",
};

/// Exec under a FUSE mount without chroot (dynamic linker invoked with host paths).
pub fn execViaFuseMount(
    mount_dir: []const u8,
    vfs_exec: []const u8,
    cmd_argv: []const []const u8,
) noreturn {
    const host_bin = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, vfs_exec }) catch std.c._exit(127);
    defer std.heap.page_allocator.free(host_bin);
    const host_bin_z = std.heap.page_allocator.allocSentinel(u8, host_bin.len, 0) catch std.c._exit(127);
    @memcpy(host_bin_z, host_bin);

    var host_argv_storage: [32][*:0]const u8 = undefined;
    var host_argc: usize = 0;
    host_argv_storage[host_argc] = host_bin_z.ptr;
    host_argc += 1;
    for (cmd_argv[1..]) |arg| {
        if (host_argc >= host_argv_storage.len) std.c._exit(127);
        const z = std.heap.page_allocator.allocSentinel(u8, arg.len, 0) catch std.c._exit(127);
        @memcpy(z, arg);
        host_argv_storage[host_argc] = z.ptr;
        host_argc += 1;
    }
    var host_cargv: [33:null]?[*:0]const u8 = undefined;
    for (0..host_argc) |i| host_cargv[i] = host_argv_storage[i];
    host_cargv[host_argc] = null;
    _ = std.c.execve(host_bin_z.ptr, @ptrCast(&host_cargv), std.c.environ);

    for (interpreter_candidates) |interp_vfs| {
        const host_ld = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ mount_dir, interp_vfs }) catch continue;
        defer std.heap.page_allocator.free(host_ld);
        if (!posix_util.access(host_ld)) continue;
        const ld_z = std.heap.page_allocator.allocSentinel(u8, host_ld.len, 0) catch std.c._exit(127);
        defer std.heap.page_allocator.free(ld_z);
        @memcpy(ld_z, host_ld);

        var argv_storage: [32][*:0]const u8 = undefined;
        var argc: usize = 0;
        argv_storage[argc] = ld_z.ptr;
        argc += 1;
        argv_storage[argc] = host_bin_z.ptr;
        argc += 1;
        for (cmd_argv[1..]) |arg| {
            if (argc >= argv_storage.len) std.c._exit(127);
            const z = std.heap.page_allocator.allocSentinel(u8, arg.len, 0) catch std.c._exit(127);
            @memcpy(z, arg);
            argv_storage[argc] = z.ptr;
            argc += 1;
        }
        var cargv: [33:null]?[*:0]const u8 = undefined;
        for (0..argc) |i| cargv[i] = argv_storage[i];
        cargv[argc] = null;
        _ = std.c.execve(ld_z.ptr, @ptrCast(&cargv), std.c.environ);
    }
    std.c._exit(127);
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
