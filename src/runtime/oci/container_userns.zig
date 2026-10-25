//! Detect whether unprivileged user namespaces work for this voila binary (AppArmor-aware).
const std = @import("std");
const posix_util = @import("sys").posix_util;

fn probeOnce() bool {
    const exe = posix_util.selfExePath(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(exe);
    const exe_z = std.heap.page_allocator.allocSentinel(u8, exe.len, 0) catch return false;
    defer std.heap.page_allocator.free(exe_z);
    @memcpy(exe_z, exe);
    const arg0 = exe_z.ptr;
    const arg1: [*:0]const u8 = "userns-probe";
    var argv: [3:null]?[*:0]const u8 = .{ arg0, arg1, null };

    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.execve(arg0, @ptrCast(&argv), std.c.environ);
        std.c._exit(127);
    }
    if (pid < 0) return false;
    var status: i32 = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(-1) == .INTR) {}
    const st: u32 = @bitCast(status);
    return std.c.W.IFEXITED(st) and std.c.W.EXITSTATUS(st) == 0;
}

var cached: ?bool = null;

pub fn available() bool {
    if (cached) |v| return v;
    const v = probeOnce();
    cached = v;
    return v;
}

pub fn probeNow(_: std.Io, _: std.mem.Allocator) bool {
    return probeOnce();
}

pub const Error = error{
    UserNamespacesRequired,
    ExePathFailed,
};
