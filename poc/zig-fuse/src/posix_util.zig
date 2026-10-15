const std = @import("std");

extern "c" fn system(command: [*:0]const u8) c_int;

/// Map a raw Linux syscall usize return to `std.posix.E` (uses thread errno when rc is -1).
pub fn syscallErr(rc: usize) std.posix.E {
    const signed: isize = @bitCast(rc);
    if (signed >= 0) return .SUCCESS;
    if (signed == -1) {
        const e: std.posix.E = @enumFromInt(std.c._errno().*);
        if (e != .SUCCESS) return e;
    }
    return std.posix.errno(rc);
}

pub fn syscallFailed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

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
    return !syscallFailed(rc);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const path_z = try toZ(allocator, path);
    defer allocator.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        const open_err: std.posix.E = @enumFromInt(std.c._errno().*);
        if (open_err == .SUCCESS) return error.Unexpected;
        return std.posix.unexpectedErrno(open_err);
    }
    defer _ = std.c.close(fd);
    var buf = try allocator.alloc(u8, 0);
    var total: usize = 0;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, chunk[0..].ptr, chunk.len);
        if (n < 0) {
            const rd_err: std.posix.E = @enumFromInt(std.c._errno().*);
            if (rd_err == .SUCCESS) return error.Unexpected;
            return std.posix.unexpectedErrno(rd_err);
        }
        if (n == 0) break;
        const got: usize = @intCast(n);
        total += got;
        if (total > limit) return error.FileTooLarge;
        buf = try allocator.realloc(buf, total);
        @memcpy(buf[total - got .. total], chunk[0..got]);
    }
    return buf;
}

pub fn unlink(path: []const u8) void {
    const path_z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(path_z);
    @memcpy(path_z, path);
    _ = std.c.unlink(path_z);
}

pub fn makePath(path: []const u8) !void {
    if (access(path)) return;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.c.mkdir(buf[0..path.len :0], 0o755);
    if (rc == 0) return;
    const err: std.posix.E = @enumFromInt(std.c._errno().*);
    if (err == .EXIST) return;
    if (err == .SUCCESS) return error.Unexpected;
    return std.posix.unexpectedErrno(err);
}
