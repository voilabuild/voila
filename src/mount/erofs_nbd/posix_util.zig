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

fn openReadOnly(path: [:0]const u8) !std.posix.fd_t {
    const fd_raw = std.os.linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    const fd_isize: isize = @bitCast(fd_raw);
    if (fd_isize < 0) return std.posix.unexpectedErrno(std.os.linux.errno(fd_raw));
    return @intCast(fd_isize);
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
    const fd = openReadOnly(path_z) catch |e| return e;
    defer _ = std.c.close(fd);
    var buf = try allocator.alloc(u8, 0);
    var total: usize = 0;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n: isize = std.c.read(@intCast(fd), chunk[0..].ptr, chunk.len);
        if (n < 0) return std.posix.unexpectedErrno(std.posix.errno(@as(usize, @bitCast(n))));
        if (n == 0) break;
        const got: usize = @intCast(n);
        total += got;
        if (total > limit) return error.FileTooLarge;
        buf = try allocator.realloc(buf, total);
        @memcpy(buf[total - got .. total], chunk[0..got]);
    }
    return buf;
}

pub fn makePath(path: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z = buf[0..path.len :0];
    if (access(path)) return;
    const rc = std.os.linux.mkdir(path_z, 0o755);
    if (rc == 0) return;
    const err = std.posix.errno(rc);
    if (err == .EXIST) return;
    if (access(path)) return;
    if (err == .SUCCESS) return error.PathCreateFailed;
    return std.posix.unexpectedErrno(err);
}
