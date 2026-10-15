const std = @import("std");
const posix_util = @import("posix_util.zig");
const fuse_serve = @import("fuse_serve.zig");
const vfs_mod = @import("vfs.zig");

pub fn canUseFuse() bool {
    if (std.os.linux.geteuid() != 0) return false;
    return posix_util.access("/dev/fuse");
}

pub const Session = struct {
    fuse_fd: std.posix.fd_t,
    mountpoint: []const u8,
    allocator: std.mem.Allocator,
    closed: bool,

    pub fn stop(self: *Session) void {
        if (self.closed) return;
        self.closed = true;
        _ = std.c.close(self.fuse_fd);
        unmount(self.allocator, self.mountpoint);
    }

    pub fn deinit(self: *Session) void {
        if (!self.closed) self.stop();
        self.allocator.free(self.mountpoint);
    }
};

pub fn mountAndServe(io: std.Io, allocator: std.mem.Allocator, vfs: *vfs_mod.Vfs, mountpoint: []const u8) !void {
    var session = try mountSession(allocator, mountpoint);
    defer session.deinit();
    try serveSession(io, allocator, vfs, &session);
}

pub fn mountSession(allocator: std.mem.Allocator, mountpoint: []const u8) !Session {
    try posix_util.makePath(mountpoint);
    const fuse_fd = openFuseDevice() catch |e| return e;
    try mountFuse(allocator, fuse_fd, mountpoint);
    const mnt = try allocator.dupe(u8, mountpoint);
    return .{
        .fuse_fd = fuse_fd,
        .mountpoint = mnt,
        .allocator = allocator,
        .closed = false,
    };
}

pub fn serveSession(io: std.Io, allocator: std.mem.Allocator, vfs: *vfs_mod.Vfs, session: *Session) !void {
    const read_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(read_buf);
    const reply_buf = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(reply_buf);

    var srv: fuse_serve.Server = .{
        .fuse_fd = session.fuse_fd,
        .vfs = vfs,
        .io = io,
        .allocator = allocator,
        .read_buf = read_buf,
        .reply_buf = reply_buf,
    };
    try srv.serve();
}

fn openFuseDevice() !std.posix.fd_t {
    const path = "/dev/fuse";
    const fd_rc = std.os.linux.open(path, .{ .ACCMODE = .RDWR }, 0);
    if (posix_util.syscallFailed(fd_rc)) {
        const err = posix_util.syscallErr(fd_rc);
        if (err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(err);
    }
    return @intCast(fd_rc);
}

fn mountFuse(allocator: std.mem.Allocator, fuse_fd: std.posix.fd_t, mountpoint: []const u8) !void {
    const opts = try std.fmt.allocPrint(allocator, "fd={},rootmode=040000,user_id=0,group_id=0", .{fuse_fd});
    defer allocator.free(opts);
    const opts_z = try allocator.allocSentinel(u8, opts.len, 0);
    defer allocator.free(opts_z);
    @memcpy(opts_z, opts);

    const mnt_z = try allocator.allocSentinel(u8, mountpoint.len, 0);
    defer allocator.free(mnt_z);
    @memcpy(mnt_z, mountpoint);

    const source = "zig-fuse";
    const source_z = try allocator.allocSentinel(u8, source.len, 0);
    defer allocator.free(source_z);
    @memcpy(source_z, source);

    const fstype = "fuse";
    const fstype_z = try allocator.allocSentinel(u8, fstype.len, 0);
    defer allocator.free(fstype_z);
    @memcpy(fstype_z, fstype);

    const flags: u32 = std.os.linux.MS.NODEV | std.os.linux.MS.NOSUID | std.os.linux.MS.RDONLY;
    const rc = std.os.linux.mount(
        source_z,
        mnt_z,
        fstype_z,
        flags,
        @intFromPtr(opts_z.ptr),
    );
    if (posix_util.syscallFailed(rc)) {
        const merr = posix_util.syscallErr(rc);
        if (merr == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(merr);
    }
}

fn unmount(allocator: std.mem.Allocator, mountpoint: []const u8) void {
    const cmd = std.fmt.allocPrint(allocator, "umount -l {s}", .{mountpoint}) catch return;
    defer allocator.free(cmd);
    const cmd_z = allocator.allocSentinel(u8, cmd.len, 0) catch return;
    defer allocator.free(cmd_z);
    @memcpy(cmd_z, cmd);
    _ = posix_util.shell(cmd_z);
}
