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

test "privileged: a netns listen is not reachable on the host" {
    const ns = @import("ns.zig");
    var up: [2]linux.fd_t = undefined;
    var down: [2]linux.fd_t = undefined;
    if (linux.pipe2(&up, linux.O{ .CLOEXEC = true }) != 0) return error.SkipZigTest;
    if (linux.pipe2(&down, linux.O{ .CLOEXEC = true }) != 0) return error.SkipZigTest;
    const pid_rc = linux.fork();
    if (posix_util.syscallFailed(pid_rc)) return error.SkipZigTest;
    if (pid_rc == 0) {
        _ = linux.close(up[0]);
        _ = linux.close(down[1]);
        const user = linux.unshare(linux.CLONE.NEWUSER);
        const net = linux.unshare(linux.CLONE.NEWNET);
        if (posix_util.syscallFailed(user) or posix_util.syscallFailed(net)) {
            linux.exit(3);
        }
        var ready: u8 = 1;
        _ = linux.write(up[1], @ptrCast(&ready), 1);
        var ack: u8 = 0;
        if (linux.read(down[0], @ptrCast(&ack), 1) != 1) linux.exit(4);
        ns.bringUpLoopback() catch linux.exit(5);
        const port = bindEphemeral() catch linux.exit(6);
        var port_be = std.mem.nativeToBig(u16, port);
        _ = linux.write(up[1], std.mem.asBytes(&port_be).ptr, 2);
        pauseForever();
    }
    _ = linux.close(up[1]);
    _ = linux.close(down[0]);
    defer {
        _ = linux.close(up[0]);
        _ = linux.close(down[1]);
    }
    var ready: u8 = 0;
    if (linux.read(up[0], @ptrCast(&ready), 1) != 1) return error.SkipZigTest;
    const pid: linux.pid_t = @intCast(pid_rc);
    if (!writeChildIdMaps(pid)) {
        _ = linux.kill(pid, linux.SIG.KILL);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return error.SkipZigTest;
    }
    var ack: u8 = 1;
    _ = linux.write(down[1], @ptrCast(&ack), 1);
    var port_be: u16 = 0;
    if (linux.read(up[0], std.mem.asBytes(&port_be).ptr, 2) != 2) {
        _ = linux.kill(pid, linux.SIG.KILL);
        var status: i32 = 0;
        _ = linux.waitpid(pid, &status, 0);
        return error.SkipZigTest;
    }
    const port = std.mem.bigToNative(u16, port_be);
    const leaked = hostCanConnect(port);
    _ = linux.kill(pid, linux.SIG.KILL);
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
    try std.testing.expect(!leaked);
}

fn bindEphemeral() !u16 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix_util.syscallFailed(rc)) return error.SkipZigTest;
    const fd: linux.fd_t = @intCast(rc);
    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = 0;
    addr.addr = 0;
    if (posix_util.syscallFailed(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)))) return error.SkipZigTest;
    if (posix_util.syscallFailed(linux.listen(fd, 1))) return error.SkipZigTest;
    var got = std.mem.zeroes(linux.sockaddr.in);
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (posix_util.syscallFailed(linux.getsockname(fd, @ptrCast(&got), &len))) return error.SkipZigTest;
    return std.mem.bigToNative(u16, got.port);
}

fn pauseForever() noreturn {
    while (true) _ = linux.pause();
}

fn hostCanConnect(port: u16) bool {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix_util.syscallFailed(rc)) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var addr = std.mem.zeroes(linux.sockaddr.in);
    addr.family = linux.AF.INET;
    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    return !posix_util.syscallFailed(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
}

fn writeChildIdMaps(pid: linux.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const uid = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/uid_map", .{pid}, 0) catch return false;
    var data_buf: [64]u8 = undefined;
    const uid_line = std.fmt.bufPrint(&data_buf, "0 {d} 1\n", .{linux.geteuid()}) catch return false;
    if (!writeProc(uid, uid_line)) return false;
    const setgroups = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/setgroups", .{pid}, 0) catch return false;
    _ = writeProc(setgroups, "deny\n");
    const gid = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/gid_map", .{pid}, 0) catch return false;
    const gid_line = std.fmt.bufPrint(&data_buf, "0 {d} 1\n", .{linux.getegid()}) catch return false;
    return writeProc(gid, gid_line);
}

fn writeProc(path: [:0]const u8, data: []const u8) bool {
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (posix_util.syscallFailed(fd)) return false;
    defer _ = linux.close(@intCast(fd));
    const n = linux.write(@intCast(fd), data.ptr, data.len);
    return n == data.len;
}
