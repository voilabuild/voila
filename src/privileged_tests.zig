const std = @import("std");
const linux = std.os.linux;
const posix_util = @import("sys/posix_util.zig");

fn requireRoot() !void {
    if (linux.geteuid() != 0) return error.SkipZigTest;
}

fn requirePath(path: []const u8) !void {
    if (!posix_util.access(path)) return error.SkipZigTest;
}

fn onPath(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "/usr/sbin", "/usr/bin", "/sbin", "/bin", "/usr/local/bin" }) |dir| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
        if (posix_util.access(p)) return true;
    }
    return false;
}

test "privileged: /dev/fuse opens read-write" {
    try requirePath("/dev/fuse");
    const rc = linux.open("/dev/fuse", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (posix_util.syscallFailed(rc)) return error.SkipZigTest;
    _ = linux.close(@intCast(rc));
}

test "privileged: unshare user namespace in a child" {
    const pid_rc = linux.fork();
    if (posix_util.syscallFailed(pid_rc)) return error.SkipZigTest;
    if (pid_rc == 0) {
        const rc = linux.unshare(linux.CLONE.NEWUSER);
        linux.exit(if (posix_util.syscallFailed(rc)) 3 else 0);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid_rc), &status, 0);
    const st: u32 = @bitCast(status);
    if (linux.W.IFEXITED(st) and linux.W.EXITSTATUS(st) == 3) return error.SkipZigTest;
    try std.testing.expect(linux.W.IFEXITED(st));
    try std.testing.expectEqual(@as(u8, 0), linux.W.EXITSTATUS(st));
}

test "privileged: erofs and runc tooling present" {
    try requireRoot();
    if (!onPath("mkfs.erofs") or !onPath("runc")) return error.SkipZigTest;
}

test "privileged: nbd device available" {
    try requireRoot();
    try requirePath("/dev/nbd0");
}
