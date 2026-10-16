const std = @import("std");

extern "c" fn system(command: [*:0]const u8) c_int;

pub fn shell(command: [:0]const u8) c_int {
    return system(command.ptr);
}

fn toZ(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const out = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(out, path);
    return out;
}

pub fn access(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.access(buf[0..path.len :0], 0);
    return rc == 0;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const path_z = try toZ(allocator, path);
    defer allocator.free(path_z);
    const fd_rc = std.os.linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    const open_err = std.posix.errno(fd_rc);
    if (open_err != .SUCCESS) return std.posix.unexpectedErrno(open_err);
    const fd: std.posix.fd_t = @intCast(fd_rc);
    defer _ = std.c.close(fd);
    var buf = try allocator.alloc(u8, 0);
    var total: usize = 0;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, chunk[0..]) catch |e| return e;
        if (n == 0) break;
        total += n;
        if (total > limit) return error.FileTooLarge;
        buf = try allocator.realloc(buf, total);
        @memcpy(buf[total - n .. total], chunk[0..n]);
    }
    return buf;
}

pub fn makePath(path: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.os.linux.mkdir(buf[0..path.len :0], 0o755);
    if (rc == 0) return;
    const err = std.posix.errno(rc);
    if (err == .EXIST) return;
    return std.posix.unexpectedErrno(err);
}
