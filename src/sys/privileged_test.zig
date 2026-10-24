const std = @import("std");
const linux = std.os.linux;
const posix_util = @import("posix_util.zig");

fn requirePath(path: []const u8) !void {
    if (!posix_util.access(path)) return error.SkipZigTest;
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
